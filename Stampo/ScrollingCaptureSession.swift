import AppKit
import ApplicationServices
import ScreenCaptureKit

@MainActor
final class ScrollingCaptureSession {
    var onFinished: ((CGImage) -> Void)?
    var onCancelled: (() -> Void)?

    private let selection: WindowPickerSelection
    private let axis: ScrollAxis
    private let delaySeconds: Int
    private let source = WindowFrameSource()
    private var hud: ScrollingCaptureHUD?
    private var escapeToken: UUID?
    private var task: Task<Void, Never>?
    private var stopped = false
    private var viewport: ScrollViewport?
    private var scale: CGFloat = 1
    private var lastStatus = "Preparing capture…"
    private var assembler: ImageAssembler
    private var previous: CaptureFrame?
    private var zeroMotionCount = 0
    private var consecutiveFailures = 0
    private let startedAt = Date()

    init(selection: WindowPickerSelection, axis: ScrollAxis, delaySeconds: Int = 0) {
        self.selection = selection
        self.axis = axis
        self.delaySeconds = max(0, delaySeconds)
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
        do {
            viewport = try ScrollDriver.viewport(selection: selection)
            scale = Self.backingScale(for: selection.bounds)
        } catch {
            UserFacingError.present(.screenCaptureFailed(reason: localizedMessage(for: error)))
            cancel()
            return
        }
        let windowScreen = NSScreen.screens.first { Self.appKitFrame(from: selection.bounds).intersects($0.frame) }
        hud = ScrollingCaptureHUD(axis: axis, onFinish: { [weak self] in self?.finish() },
                                  onCancel: { [weak self] in self?.cancel() })
        hud?.show(on: windowScreen ?? NSScreen.main ?? NSScreen.screens.first)
        escapeToken = TransientHotkeyCenter.escape.push { [weak self] in self?.cancel() }
        task = Task { [weak self] in await self?.run() }
    }

    func finish() {
        guard !stopped else { return }
        stopped = true
        task?.cancel()
        cleanup()
        do {
            let image = try assembler.makeImage(maxPixels: 20_000_000)
            onFinished?(image)
        } catch {
            UserFacingError.present(.screenCaptureFailed(reason: error.localizedDescription))
            onCancelled?()
        }
    }

    func cancel() {
        guard !stopped else { return }
        stopped = true
        task?.cancel()
        cleanup()
        onCancelled?()
    }

    private func cleanup() {
        hud?.close()
        hud = nil
        if let escapeToken { TransientHotkeyCenter.escape.remove(escapeToken) }
        escapeToken = nil
        task = nil
    }

    private func run() async {
        do {
            if delaySeconds > 0 {
                hud?.update(String(format: LocaleManager.shared.string("Starting in %d seconds…"), delaySeconds))
                try await Task.sleep(for: .seconds(delaySeconds))
            }
            try await waitForTargetFocus()
            try checkWindowAndFocus()
            let initialViewport = try await captureViewport()
            try checkWindowAndFocus()
            let probeStep = max(24, min(56, axisLength(of: initialViewport) / 10))
            try ScrollDriver.sendScroll(axis: axis, pixels: probeStep, at: currentScrollPoint())
            let probeViewport = try await captureStableViewport(reference: initialViewport)
            try checkWindowAndFocus()
            let probeMotionLimit = ScrollDriver.maximumLikelyMovement(pixelStep: probeStep,
                                                                       backingScale: scale,
                                                                       viewportLength: axisLength(of: initialViewport))
            guard let movingRect = Self.movingContentRect(before: initialViewport, after: probeViewport, axis: axis),
                  let first = initialViewport.cropped(to: movingRect),
                  let probe = probeViewport.cropped(to: movingRect)
            else { throw ScrollDriverError.scrollAreaUnavailable }
            if let viewport {
                self.viewport = ScrollViewport(
                    windowRect: viewport.windowRect.offsetBy(dx: movingRect.minX / scale,
                                                            dy: movingRect.minY / scale),
                    relativeScrollPoint: viewport.relativeScrollPoint,
                    windowBounds: viewport.windowBounds
                )
            }
            assembler.begin(with: first)
            previous = probe
            lastStatus = axis == .vertical ? LocaleManager.shared.string("Scroll down to capture more") : LocaleManager.shared.string("Scroll right to capture more")
            hud?.update(lastStatus)
            var requestedStep = max(24, Int(Double(axisLength(of: first)) * 0.60))
            var unmatchedScroll = 0

            do {
                let match = try FrameMatcher.match(previous: first, current: probe, axis: axis,
                                                   maximumOffset: probeMotionLimit + 24)
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
                    hud?.update(LocaleManager.shared.string("Time limit reached · Finish to save or Cancel to discard"))
                    return
                }
                guard assembler.totalLength < 20_000,
                      (axis == .vertical ? first.width * assembler.totalLength : first.height * assembler.totalLength) < 20_000_000 else {
                    hud?.update(LocaleManager.shared.string("Size limit reached · Finish to save or Cancel to discard"))
                    return
                }
                guard let oldFrame = previous else { return }
                try checkWindowAndFocus()
                let currentStep = min(requestedStep, max(24, axisLength(of: oldFrame) * 3 / 4))
                let motionLimit = ScrollDriver.maximumLikelyMovement(pixelStep: currentStep,
                                                                      backingScale: scale,
                                                                      viewportLength: axisLength(of: oldFrame))
                let point = currentScrollPoint()
                try ScrollDriver.sendScroll(axis: axis, pixels: currentStep, at: point)
                let next = try await captureStableViewport(reference: oldFrame)
                if Task.isCancelled || stopped { return }
                try checkWindowAndFocus()

                if meanDifference(oldFrame, next) < 0.006 {
                    zeroMotionCount += 1
                    consecutiveFailures = 0
                    lastStatus = zeroMotionCount >= 3
                        ? LocaleManager.shared.string("End of scroll area · Finish to save or Cancel to discard")
                        : LocaleManager.shared.string("No movement detected · checking…")
                    hud?.update(lastStatus)
                    if zeroMotionCount >= 3 { return }
                    // Move a little farther to rule out a missed high-resolution event.
                    continue
                }
                zeroMotionCount = 0
                do {
                    let axis = self.axis
                    let match = try await Task.detached(priority: .userInitiated) {
                        try FrameMatcher.match(previous: oldFrame, current: next, axis: axis,
                                               maximumOffset: motionLimit + unmatchedScroll + 32)
                    }.value
                    let combinedLength = assembler.totalLength + match.offset
                    let crossLength = axis == .vertical ? next.width : next.height
                    guard combinedLength <= 20_000, crossLength * combinedLength <= 20_000_000 else {
                        hud?.update(LocaleManager.shared.string("Size limit reached · Finish to save or Cancel to discard"))
                        return
                    }
                    try assembler.append(next, movement: match.offset)
                    previous = next
                    unmatchedScroll = 0
                    requestedStep = max(24, Int(Double(axisLength(of: next)) * 0.60))
                    consecutiveFailures = 0
                    let statusKey = axis == .vertical ? "Captured %d pixels · scroll down" : "Captured %d pixels · scroll right"
                    hud?.update(String(format: LocaleManager.shared.string(statusKey), assembler.totalLength))
                } catch {
                    consecutiveFailures += 1
                    if consecutiveFailures <= 2 {
                        // Retry from the same stable frame with a smaller probe;
                        // do not append a questionable match.
                        requestedStep = max(12, currentStep / 2)
                        unmatchedScroll += motionLimit
                        hud?.update(LocaleManager.shared.string("Unclear frame · retrying with a shorter scroll…"))
                    } else {
                        hud?.update(LocaleManager.shared.string("Could not align frame · Finish to save or Cancel to discard"))
                        return
                    }
                }
            }
        } catch is CancellationError {
            return
        } catch {
            if !stopped {
                guard !assembler.strips.isEmpty else {
                    UserFacingError.present(.screenCaptureFailed(reason: localizedMessage(for: error)))
                    cancel()
                    return
                }
                let message = localizedMessage(for: error)
                hud?.update("\(message) · \(LocaleManager.shared.string("Finish to save or Cancel to discard"))")
                lastStatus = message
            }
        }
    }

    private func captureViewport() async throws -> CaptureFrame {
        guard let viewport else { throw ScrollDriverError.scrollAreaUnavailable }
        let full = try await source.capture(windowID: selection.windowID, scale: scale)
        let x = (viewport.windowRect.minX - viewport.windowBounds.minX) * scale
        let y = (viewport.windowRect.minY - viewport.windowBounds.minY) * scale
        let rect = CGRect(x: x, y: y, width: viewport.windowRect.width * scale,
                          height: viewport.windowRect.height * scale)
        guard let crop = full.cropped(to: rect) else { throw WindowFrameSourceError.invalidFrame }
        return crop
    }

    private func captureStableViewport(reference: CaptureFrame) async throws -> CaptureFrame {
        var latest = try await captureViewport()
        let deadline = Date().addingTimeInterval(1.8)
        while Date() < deadline && !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(140))
            let next = try await captureViewport()
            let change = meanDifference(latest, next)
            latest = next
            if change < 0.003 { return latest }
        }
        // Slow animations do not get to block a user indefinitely; the matcher
        // still has independent-region checks before it will append anything.
        return latest
    }

    private func checkWindowAndFocus() throws {
        guard let now = ScrollDriver.currentWindowBounds(selection.windowID) else {
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
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == selection.processID { return }
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

    /// Trims sticky controls from the AX-provided scroll viewport by comparing
    /// the small probe pair. The first-to-last active band is the portion that
    /// actually moved; fixed headers and toolbars are left out of every frame.
    private static func movingContentRect(before: CaptureFrame, after: CaptureFrame,
                                          axis: ScrollAxis) -> CGRect? {
        guard before.width == after.width, before.height == after.height else { return nil }
        let length = axis == .vertical ? before.height : before.width
        let cross = axis == .vertical ? before.width : before.height
        guard length >= 120, cross >= 80 else { return nil }
        var first: Int?, last: Int?
        for along in 0..<length {
            var total = 0.0
            let strideCross = max(1, cross / 220)
            var count = 0
            for across in stride(from: 0, to: cross, by: strideCross) {
                let x = axis == .vertical ? across : along
                let y = axis == .vertical ? along : across
                let i = (y * before.width + x) * 4
                total += Double(abs(Int(before.pixels[i]) - Int(after.pixels[i]))
                              + abs(Int(before.pixels[i + 1]) - Int(after.pixels[i + 1]))
                              + abs(Int(before.pixels[i + 2]) - Int(after.pixels[i + 2]))) / 765
                count += 1
            }
            if total / Double(max(1, count)) > 0.012 {
                if first == nil { first = along }
                last = along
            }
        }
        guard let first, let last, last - first >= length / 3 else { return nil }
        let padding = 8
        let lower = max(0, first - padding)
        let upper = min(length, last + padding + 1)
        guard upper - lower >= length / 3 else { return nil }
        return axis == .vertical
            ? CGRect(x: 0, y: lower, width: before.width, height: upper - lower)
            : CGRect(x: lower, y: 0, width: upper - lower, height: before.height)
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
