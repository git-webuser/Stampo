import AppKit
import ApplicationServices
import ScreenCaptureKit
import os

@MainActor
final class ScrollingCaptureSession {
    private enum State { case preparing, capturing, awaitingDecision, finished }
    private enum DiagnosticStage: String {
        case raiseWindow, resolveViewport, validateTarget, capture, probeMotion, match, save
    }

    var onFinished: ((CGImage) -> Void)?
    var onCancelled: (() -> Void)?

    private let selection: WindowPickerSelection
    private let axis: ScrollAxis
    private let delaySeconds: Int
    private let activateSelectedWindow: @MainActor (WindowPickerSelection) throws -> Void
    private let source = WindowFrameSource()
    private var hud: ScrollingCaptureHUD?
    private var escapeToken: UUID?
    private var task: Task<Void, Never>?
    private var stopped = false
    private var state: State = .preparing
    private var diagnosticStage: DiagnosticStage = .raiseWindow
    private var viewport: ScrollViewport?
    private var scrollContainer: AXUIElement?
    private var scale: CGFloat = 1
    private var lastStatus = "Preparing capture…"
    private var assembler: ImageAssembler
    private var previous: CaptureFrame?
    private var zeroMotionCount = 0
    private var consecutiveFailures = 0
    private let startedAt = Date()

    init(selection: WindowPickerSelection, axis: ScrollAxis, delaySeconds: Int = 0,
         activateSelectedWindow: (@MainActor (WindowPickerSelection) throws -> Void)? = nil) {
        self.selection = selection
        self.axis = axis
        self.delaySeconds = max(0, delaySeconds)
        self.activateSelectedWindow = activateSelectedWindow ?? { selected in
            try ScrollDriver.raiseSelectedWindow(selected)
        }
        self.assembler = ImageAssembler(axis: axis)
    }

    func start() {
        guard !stopped else { return }
        guard CGPreflightScreenCaptureAccess() else {
            UserFacingError.present(.screenCaptureFailed(reason: LocaleManager.shared.string("Grant Screen Recording access to Stampo, then try again.")))
            cancel()
            return
        }
        guard ScrollDriver.accessibilityIsTrusted(prompt: true) else {
            UserFacingError.present(.accessibilityPermission)
            cancel()
            return
        }
        let windowScreen = NSScreen.screens.first { Self.appKitFrame(from: selection.bounds).intersects($0.frame) }
        hud = ScrollingCaptureHUD(axis: axis, onFinish: { [weak self] in self?.finish() },
                                  onCancel: { [weak self] in self?.cancel() })
        hud?.show(on: windowScreen ?? NSScreen.main ?? NSScreen.screens.first)
        escapeToken = TransientHotkeyCenter.escape.push { [weak self] in self?.cancel() }
        _ = scheduleRun()
    }

    @discardableResult
    func scheduleRun() -> Task<Void, Never> {
        let scheduled = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.run()
        }
        task = scheduled
        return scheduled
    }

    func finish() {
        guard !stopped else { return }
        stopped = true
        state = .finished
        task?.cancel()
        cleanup()
        do {
            let image = try assembler.makeImage(maxPixels: 20_000_000)
            releaseCaptureBuffers()
            onFinished?(image)
        } catch {
            releaseCaptureBuffers()
            diagnosticStage = .save
            logFailure(error)
            presentFailure(error)
            onCancelled?()
        }
    }

    func cancel() {
        guard !stopped else { return }
        stopped = true
        state = .finished
        task?.cancel()
        cleanup()
        releaseCaptureBuffers()
        onCancelled?()
    }

    private func cleanup() {
        hud?.close()
        hud = nil
        if let escapeToken { TransientHotkeyCenter.escape.remove(escapeToken) }
        escapeToken = nil
        task = nil
        scrollContainer = nil
    }

    private func releaseCaptureBuffers() {
        previous = nil
        assembler.reset()
    }

    private func ensureActive() throws {
        guard !Task.isCancelled, !stopped else { throw CancellationError() }
    }

    func run() async {
        do {
            try ensureActive()
            if delaySeconds > 0 {
                hud?.update(String(format: LocaleManager.shared.string("Starting in %d seconds…"), delaySeconds))
                try await Task.sleep(for: .seconds(delaySeconds))
            }
            try ensureActive()
            diagnosticStage = .raiseWindow
            try activateSelectedWindow(selection)
            try await waitForTargetFocus()
            try ensureActive()
            scale = Self.backingScale(for: selection.bounds)
            try checkWindowAndFocus()
            diagnosticStage = .resolveViewport
            switch try ScrollDriver.viewport(selection: selection) {
            case .accessibility(let resolved, let container):
                viewport = resolved
                scrollContainer = container
                diagnosticStage = .validateTarget
                do {
                    try ScrollDriver.validateScrollTarget(selection: selection, point: selection.clickPoint,
                                                          container: container)
                } catch ScrollDriverError.scrollAreaUnavailable {
                    // AX may expose a partial Chromium tree: keep the selected
                    // CG window and let the pixel probe establish the viewport.
                    Log.capture.info("scroll capture viewport fallback: AX target identity was incomplete")
                    viewport = ScrollDriver.windowFallbackViewport(for: selection)
                    scrollContainer = nil
                    try ScrollDriver.validateSelectedWindow(selection: selection, point: selection.clickPoint)
                }
            case .window(let resolved):
                // Chromium and other complex apps may provide a window capture
                // before exposing a complete AXWebArea chain. Pixel probing
                // will reduce this to the region that actually moves.
                viewport = resolved
                scrollContainer = nil
                Log.capture.info("scroll capture viewport fallback: AX hit did not resolve a suitable scroll container")
                diagnosticStage = .validateTarget
                try ScrollDriver.validateSelectedWindow(selection: selection, point: selection.clickPoint)
            }
            state = .capturing
            diagnosticStage = .capture
            let initialViewport = try await ScrollCaptureCancellationBoundary.awaitActive {
                try await self.captureViewport()
            }
            try ensureActive()
            try checkWindowAndFocus()
            let probeStep = max(24, min(56, axisLength(of: initialViewport) / 10))
            try ensureActive()
            let probePoint = currentScrollPoint()
            diagnosticStage = .probeMotion
            try validateCurrentScrollTarget(at: probePoint)
            try ScrollDriver.sendScroll(axis: axis, pixels: probeStep, at: probePoint)
            let probeViewport = try await ScrollCaptureCancellationBoundary.awaitActive {
                try await self.captureStableViewport(reference: initialViewport)
            }
            try ensureActive()
            try checkWindowAndFocus()
            let probeMotionLimit = ScrollDriver.maximumLikelyMovement(pixelStep: probeStep,
                                                                       backingScale: scale,
                                                                       viewportLength: axisLength(of: initialViewport))
            guard let movingRect = Self.movingContentRect(before: initialViewport, after: probeViewport, axis: axis),
                  let first = initialViewport.cropped(to: movingRect),
                  let probe = probeViewport.cropped(to: movingRect)
            else { throw ScrollDriverError.noMovingContent }
            guard let viewport, let croppedViewport = viewport.cropped(to: movingRect, backingScale: scale) else {
                throw ScrollDriverError.scrollAreaUnavailable
            }
            self.viewport = croppedViewport
            assembler.begin(with: first)
            previous = probe
            lastStatus = LocaleManager.shared.string("Capturing automatically…")
            hud?.update(lastStatus)
            var requestedStep = max(24, Int(Double(axisLength(of: first)) * 0.60))
            var unmatchedScroll = 0

            do {
                diagnosticStage = .match
                let match = try FrameMatcher.match(previous: first, current: probe, axis: axis,
                                                   maximumOffset: probeMotionLimit + 24)
                try ensureActive()
                try assembler.append(probe, movement: match.offset)
            } catch {
                // The selected scroll view did not yield stable moving content
                // across the probe; keep the initial image for a partial save.
                previous = first
                unmatchedScroll = probeStep
                consecutiveFailures = 1
                hud?.update(LocaleManager.shared.string("Unclear frame · retrying with a shorter scroll…"))
            }

            while !Task.isCancelled && !stopped {
                guard Date().timeIntervalSince(startedAt) < 90 else {
                    pause(with: LocaleManager.shared.string("Time limit reached · Finish to save or Cancel to discard"))
                    return
                }
                guard assembler.totalLength < 20_000,
                      (axis == .vertical ? first.width * assembler.totalLength : first.height * assembler.totalLength) < 20_000_000 else {
                    pause(with: LocaleManager.shared.string("Size limit reached · Finish to save or Cancel to discard"))
                    return
                }
                guard let oldFrame = previous else { return }
                try checkWindowAndFocus()
                let currentStep = min(requestedStep, max(24, axisLength(of: oldFrame) * 3 / 4))
                let motionLimit = ScrollDriver.maximumLikelyMovement(pixelStep: currentStep,
                                                                      backingScale: scale,
                                                                      viewportLength: axisLength(of: oldFrame))
                let point = currentScrollPoint()
                try ensureActive()
                diagnosticStage = .validateTarget
                try validateCurrentScrollTarget(at: point)
                try ScrollDriver.sendScroll(axis: axis, pixels: currentStep, at: point)
                diagnosticStage = .capture
                let next = try await ScrollCaptureCancellationBoundary.awaitActive {
                    try await self.captureStableViewport(reference: oldFrame)
                }
                try ensureActive()
                try checkWindowAndFocus()

                if meanDifference(oldFrame, next) < 0.006 {
                    zeroMotionCount += 1
                    consecutiveFailures = 0
                    if zeroMotionCount >= 3 {
                        pause(with: LocaleManager.shared.string("Capture complete · Finish to save or Cancel to discard"))
                        return
                    }
                    lastStatus = LocaleManager.shared.string("No movement detected · checking…")
                    hud?.update(lastStatus)
                    // Move a little farther to rule out a missed high-resolution event.
                    continue
                }
                zeroMotionCount = 0
                do {
                    diagnosticStage = .match
                    let axis = self.axis
                    let maximumOffset = motionLimit + unmatchedScroll + 32
                    let match = try await ScrollCaptureCancellationBoundary.awaitActive {
                        try await Task.detached(priority: .userInitiated) {
                            try FrameMatcher.match(previous: oldFrame, current: next, axis: axis,
                                                   maximumOffset: maximumOffset)
                        }.value
                    }
                    try ensureActive()
                    let combinedLength = assembler.totalLength + match.offset
                    let crossLength = axis == .vertical ? next.width : next.height
                    guard combinedLength <= 20_000, crossLength * combinedLength <= 20_000_000 else {
                        pause(with: LocaleManager.shared.string("Size limit reached · Finish to save or Cancel to discard"))
                        return
                    }
                    try ensureActive()
                    try assembler.append(next, movement: match.offset)
                    previous = next
                    unmatchedScroll = 0
                    requestedStep = max(24, Int(Double(axisLength(of: next)) * 0.60))
                    consecutiveFailures = 0
                    hud?.update(String(format: LocaleManager.shared.string("Captured %d pixels"), assembler.totalLength))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    consecutiveFailures += 1
                    if consecutiveFailures <= 2 {
                        // Retry from the same stable frame with a smaller probe;
                        // do not append a questionable match.
                        requestedStep = max(12, currentStep / 2)
                        unmatchedScroll += motionLimit
                        hud?.update(LocaleManager.shared.string("Unclear frame · retrying with a shorter scroll…"))
                    } else {
                        pause(with: LocaleManager.shared.string("Could not align frame · Finish to save or Cancel to discard"))
                        return
                    }
                }
            }
        } catch is CancellationError {
            return
        } catch {
            if !stopped {
                logFailure(error)
                guard !assembler.strips.isEmpty else {
                    presentFailure(error)
                    cancel()
                    return
                }
                let message = localizedMessage(for: error)
                pause(with: "\(message) · \(LocaleManager.shared.string("Finish to save or Cancel to discard"))")
                lastStatus = message
            }
        }
    }

    private func validateCurrentScrollTarget(at point: CGPoint) throws {
        guard scrollContainer != nil else {
            try ScrollDriver.validateSelectedWindow(selection: selection, point: point)
            return
        }
        try ScrollDriver.validateScrollTarget(selection: selection, point: point, container: scrollContainer!)
    }

    private func presentFailure(_ error: Error) {
        switch error {
        case WindowFrameSourceError.permissionDenied:
            UserFacingError.present(.screenCaptureFailed(reason: error.localizedDescription))
        case ScrollDriverError.accessibilityDenied:
            UserFacingError.present(.accessibilityPermission)
        default:
            UserFacingError.present(.scrollingCaptureFailed(reason: localizedMessage(for: error)))
        }
    }

    private func logFailure(_ error: Error) {
        Log.capture.error("scroll capture failed at stage \(self.diagnosticStage.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }

    private func pause(with message: String) {
        state = .awaitingDecision
        previous = nil
        lastStatus = message
        hud?.update(message)
    }

    private func captureViewport() async throws -> CaptureFrame {
        try ensureActive()
        guard let viewport else { throw ScrollDriverError.scrollAreaUnavailable }
        let full = try await source.capture(windowID: selection.windowID, scale: scale)
        try ensureActive()
        let pointsRect = viewport.cropRectInWindowPoints
        let rect = CGRect(x: pointsRect.minX * scale, y: pointsRect.minY * scale,
                          width: pointsRect.width * scale, height: pointsRect.height * scale)
        guard let crop = full.cropped(to: rect) else { throw WindowFrameSourceError.invalidFrame }
        return crop
    }

    private func captureStableViewport(reference: CaptureFrame) async throws -> CaptureFrame {
        var latest = try await captureViewport()
        try ensureActive()
        let deadline = Date().addingTimeInterval(1.8)
        while Date() < deadline && !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(140))
            let next = try await captureViewport()
            try ensureActive()
            let change = meanDifference(latest, next)
            latest = next
            if change < 0.003 { return latest }
        }
        // Slow animations do not get to block a user indefinitely; the matcher
        // still has independent-region checks before it will append anything.
        return latest
    }

    private func checkWindowAndFocus() throws {
        guard let now = ScrollDriver.currentWindowBounds(selection.windowID),
              ScrollDriver.currentWindowOwnerPID(selection.windowID) == selection.processID else {
            throw WindowFrameSourceError.windowUnavailable
        }
        guard abs(now.width - selection.bounds.width) < 1,
              abs(now.height - selection.bounds.height) < 1 else {
            throw WindowFrameSourceError.captureFailed(LocaleManager.shared.string("The window size changed. Finish to save the collected portion or Cancel to discard."))
        }
        guard abs(Self.backingScale(for: now) - scale) < 0.01 else {
            throw WindowFrameSourceError.captureFailed(LocaleManager.shared.string("The display scale changed. Finish to save the collected portion or Cancel to discard."))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == selection.processID else {
            throw WindowFrameSourceError.captureFailed(LocaleManager.shared.string("The selected app lost focus. Finish to save the collected portion or Cancel to discard."))
        }
    }

    private func waitForTargetFocus() async throws {
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline && !Task.isCancelled {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == selection.processID {
                do {
                    try ScrollDriver.validateSelectedWindow(selection: selection, point: selection.clickPoint)
                    return
                } catch {
                    // Wait briefly for activation to expose the exact selected
                    // window; a covered point is never sent a scroll event.
                }
            }
            try await Task.sleep(for: .milliseconds(80))
        }
        throw WindowFrameSourceError.captureFailed(LocaleManager.shared.string("The selected app lost focus. Finish to save the collected portion or Cancel to discard."))
    }

    private func currentScrollPoint() -> CGPoint {
        guard let viewport, let bounds = ScrollDriver.currentWindowBounds(selection.windowID) else {
            return selection.clickPoint
        }
        return CGPoint(x: bounds.minX + viewport.relativeScrollPoint.x,
                       y: bounds.minY + viewport.relativeScrollPoint.y)
    }

    private func axisLength(of frame: CaptureFrame) -> Int {
        axis == .vertical ? frame.height : frame.width
    }

    private func localizedMessage(for error: Error) -> String {
        guard let matchError = error as? FrameMatchError else { return error.localizedDescription }
        let key: String
        switch matchError {
        case .noReliableMotion: key = "The scrolling area did not move enough to match frames. Try clicking inside the page or table and start again."
        case .ambiguousMotion: key = "The visible content repeats too much to align reliably. The capture stopped to avoid a damaged image."
        case .crossAxisMotion: key = "The window moved in both directions. Keep the window size stable and scroll in one direction."
        case .outputLimitExceeded: key = "The scrolling image reached the configured size limit."
        }
        return LocaleManager.shared.string(key)
    }

    private func meanDifference(_ a: CaptureFrame, _ b: CaptureFrame) -> Double {
        guard a.width == b.width, a.height == b.height else { return 1 }
        let strideSize = max(4, (a.width * a.height) / 25_000)
        var total = 0.0, n = 0
        for pixel in stride(from: 0, to: a.width * a.height, by: strideSize) {
            let base = pixel * 4
            total += Double(abs(Int(a.pixels[base]) - Int(b.pixels[base]))
                          + abs(Int(a.pixels[base + 1]) - Int(b.pixels[base + 1]))
                          + abs(Int(a.pixels[base + 2]) - Int(b.pixels[base + 2]))) / 765
            n += 1
        }
        return total / Double(max(1, n))
    }

    /// Finds the 2D bounding box of pixels that changed between the probe pair.
    /// This works for an AX-resolved viewport and for a whole-window fallback,
    /// where fixed sidebars/headers must be excluded before stitching.
    nonisolated static func movingContentRect(before: CaptureFrame, after: CaptureFrame,
                                               axis: ScrollAxis) -> CGRect? {
        guard before.width == after.width, before.height == after.height else { return nil }
        let primaryLength = axis == .vertical ? before.height : before.width
        let crossLength = axis == .vertical ? before.width : before.height
        guard primaryLength >= 120, crossLength >= 80 else { return nil }

        func activeBounds(length: Int, cross: Int, xFor: (Int, Int) -> Int,
                          yFor: (Int, Int) -> Int) -> (Int, Int)? {
            var first: Int?, last: Int?
            let crossStride = max(1, cross / 220)
            for position in 0..<length {
                var total = 0.0
                var count = 0
                for across in stride(from: 0, to: cross, by: crossStride) {
                    let x = xFor(position, across), y = yFor(position, across)
                    let i = (y * before.width + x) * 4
                    total += Double(abs(Int(before.pixels[i]) - Int(after.pixels[i]))
                                  + abs(Int(before.pixels[i + 1]) - Int(after.pixels[i + 1]))
                                  + abs(Int(before.pixels[i + 2]) - Int(after.pixels[i + 2]))) / 765
                    count += 1
                }
                if total / Double(max(1, count)) > 0.012 {
                    if first == nil { first = position }
                    last = position
                }
            }
            guard let first, let last else { return nil }
            return (first, last + 1)
        }

        let primary: (Int, Int)?
        let cross: (Int, Int)?
        if axis == .vertical {
            primary = activeBounds(length: before.height, cross: before.width,
                                   xFor: { _, across in across }, yFor: { position, _ in position })
            cross = activeBounds(length: before.width, cross: before.height,
                                 xFor: { position, _ in position }, yFor: { _, across in across })
        } else {
            primary = activeBounds(length: before.width, cross: before.height,
                                   xFor: { position, _ in position }, yFor: { _, across in across })
            cross = activeBounds(length: before.height, cross: before.width,
                                 xFor: { _, across in across }, yFor: { position, _ in position })
        }
        guard let (p0, p1) = primary, let (c0, c1) = cross,
              p1 - p0 >= primaryLength / 3,
              c1 - c0 >= max(80, crossLength / 3) else { return nil }
        return axis == .vertical
            ? CGRect(x: c0, y: p0, width: c1 - c0, height: p1 - p0)
            : CGRect(x: p0, y: c0, width: p1 - p0, height: c1 - c0)
    }

    private static func backingScale(for bounds: CGRect) -> CGFloat {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return 1 }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return 1 }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        for display in displays {
            let rect = CGDisplayBounds(display)
            if rect.contains(center), rect.width > 0 {
                return max(1, CGFloat(CGDisplayPixelsWide(display)) / rect.width)
            }
        }
        return 1
    }

    /// Window-list bounds are Quartz top-left coordinates; NSScreen frames are
    /// AppKit bottom-left coordinates.
    private static func appKitFrame(from quartz: CGRect) -> CGRect {
        let display = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame
            ?? NSScreen.screens.first?.frame ?? .zero
        return CGRect(x: quartz.minX, y: display.height - quartz.maxY,
                      width: quartz.width, height: quartz.height)
    }
}

@MainActor
private final class ScrollingCaptureHUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let onFinish: () -> Void
    private let onCancel: () -> Void

    init(axis: ScrollAxis, onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onFinish = onFinish
        self.onCancel = onCancel
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 82),
                        styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = LocaleManager.shared.string(axis == .vertical ? "Vertical capture" : "Horizontal capture")
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        label.stringValue = LocaleManager.shared.string("Preparing capture…")
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let finishButton = NSButton(title: LocaleManager.shared.string("Finish"), target: nil, action: nil)
        finishButton.target = self
        finishButton.action = #selector(finishPressed)
        let cancelButton = NSButton(title: LocaleManager.shared.string("Cancel"), target: nil, action: nil)
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        buttons.addArrangedSubview(finishButton)
        buttons.addArrangedSubview(cancelButton)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView = host
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -10)
        ])
    }

    func show(on screen: NSScreen?) {
        guard let screen else { return }
        panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - panel.frame.width / 2,
                                     y: screen.visibleFrame.minY + 36))
        panel.orderFrontRegardless()
    }

    func update(_ text: String) { label.stringValue = text }
    func close() { panel.orderOut(nil) }

    @objc private func finishPressed() { onFinish() }
    @objc private func cancelPressed() { onCancel() }
}
