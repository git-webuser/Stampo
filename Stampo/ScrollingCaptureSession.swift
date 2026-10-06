import AppKit
import ApplicationServices
import ScreenCaptureKit
import os

/// What the notch strip shows while a scrolling capture runs.
enum ScrollCaptureStatus: Equatable {
    case capturing
    /// Part of the image is collected but the capture cannot go on. The
    /// reason is already localized; the strip waits for Done or ✕.
    case paused(reason: String)
    /// Done was pressed, or a limit was reached: the file is being written.
    case saving
}

@MainActor
final class ScrollingCaptureSession {
    private enum Geometry {
        static let roundedWindowEdgeInsetPoints: CGFloat = 6
        static let fallbackScrollbarInsetPoints: CGFloat = 10
    }
    private enum DiagnosticStage: String {
        case raiseWindow, resolveViewport, validateTarget, capture, probeMotion, match, save
    }

    var onFinished: ((CGImage) -> Void)?
    var onCancelled: (() -> Void)?
    var onStatus: ((ScrollCaptureStatus) -> Void)?

    private let selection: WindowPickerSelection
    /// The direction asked for until the probe has settled, the direction the
    /// capture actually goes after it: a page that does not scroll that way
    /// may scroll the other.
    private var axis: ScrollAxis
    private let excludeScrollbars: Bool
    private let activateSelectedWindow: @MainActor (WindowPickerSelection) throws -> Void
    /// Whether Stampo's own visible UI (the notch panel) is over a Quartz
    /// point. Own windows are not in the frontmost-window check.
    private let ownUICovers: @MainActor (CGPoint) -> Bool
    /// Window numbers of ours that do not count as covering the page: the
    /// notch panel's. Every other window of Stampo over the point does.
    private let ignoredWindows: @MainActor () -> Set<CGWindowID>
    private let source = WindowFrameSource()
    private var escapeToken: UUID?
    private var task: Task<Void, Never>?
    private var stopped = false
    private var diagnosticStage: DiagnosticStage = .raiseWindow
    private var viewport: ScrollViewport?
    private var scrollContainer: AXUIElement?
    private var scale: CGFloat = 1
    private var assembler: ImageAssembler
    private var previous: CaptureFrame?
    private var zeroMotionCount = 0
    private var consecutiveFailures = 0
    private let startedAt = Date()

    init(selection: WindowPickerSelection, axis: ScrollAxis,
         excludeScrollbars: Bool = true,
         activateSelectedWindow: (@MainActor (WindowPickerSelection) throws -> Void)? = nil,
         ownUICovers: @escaping @MainActor (CGPoint) -> Bool = { _ in false },
         ignoredWindows: @escaping @MainActor () -> Set<CGWindowID> = { [] }) {
        self.selection = selection
        self.axis = axis
        self.excludeScrollbars = excludeScrollbars
        self.activateSelectedWindow = activateSelectedWindow ?? { selected in
            try ScrollDriver.raiseSelectedWindow(selected, ignoring: ignoredWindows())
        }
        self.ownUICovers = ownUICovers
        self.ignoredWindows = ignoredWindows
        self.assembler = ImageAssembler(axis: axis)
    }

    func start() {
        guard !stopped else { return }
        guard CGPreflightScreenCaptureAccess() else {
            UserFacingError.present(.screenCaptureFailed(reason: LocaleManager.shared.string("Grant Screen Recording access to Stampo, then try again.")))
            cancel()
            return
        }
        // macOS asks once, in its own dialog; asking again would stack that
        // dialog on top of ours. From the second time on our alert, with its
        // button to the pane, is the only thing shown.
        let plan = Self.accessibilityPlan(promptedBefore: AppSettings.scrollAccessibilityPrompted)
        guard ScrollDriver.accessibilityIsTrusted(prompt: plan.prompt) else {
            if plan.prompt { AppSettings.scrollAccessibilityPrompted = true }
            if plan.alertIfDenied { UserFacingError.present(.accessibilityPermission) }
            cancel()
            return
        }
        escapeToken = TransientHotkeyCenter.escape.push { [weak self] in self?.cancel() }
        onStatus?(.capturing)
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
        // Done before the first frame has nothing to save, and nothing to
        // complain about: the user changed their mind.
        guard !assembler.strips.isEmpty else {
            cancel()
            return
        }
        stopped = true
        task?.cancel()
        cleanup()
        onStatus?(.saving)
        do {
            let image = try assembler.makeImage()
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
        task?.cancel()
        cleanup()
        releaseCaptureBuffers()
        onCancelled?()
    }

    private func cleanup() {
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
                                                          container: container, ignoring: ignoredWindows())
                } catch ScrollDriverError.scrollAreaUnavailable {
                    // AX may expose a partial Chromium tree: keep the selected
                    // CG window and let the pixel probe establish the viewport.
                    Log.capture.info("scroll capture viewport fallback: AX target identity was incomplete")
                    viewport = ScrollDriver.windowFallbackViewport(for: selection)
                    scrollContainer = nil
                    try ScrollDriver.validateSelectedWindow(selection: selection, point: selection.clickPoint,
                                                        ignoring: ignoredWindows())
                }
            case .window(let resolved):
                // Chromium and other complex apps may provide a window capture
                // before exposing a complete AXWebArea chain. Pixel probing
                // will reduce this to the region that actually moves.
                viewport = resolved
                scrollContainer = nil
                Log.capture.info("scroll capture viewport fallback: AX hit did not resolve a suitable scroll container")
                diagnosticStage = .validateTarget
                try ScrollDriver.validateSelectedWindow(selection: selection, point: selection.clickPoint,
                                                        ignoring: ignoredWindows())
            }
            guard let baseViewport = viewport?.insetWindowEdges(points: Geometry.roundedWindowEdgeInsetPoints) else {
                throw ScrollDriverError.scrollAreaUnavailable
            }
            viewport = baseViewport
            diagnosticStage = .capture
            // One look at the whole window before anything moves. It is the
            // start of the capture whichever way the capture ends up going, so
            // the beginning is never lost to a probe in the wrong direction —
            // and being the whole window, it can be cropped for either axis
            // without scrolling back.
            var before = try await ScrollCaptureCancellationBoundary.awaitActive {
                try await self.captureWindow()
            }
            try ensureActive()
            try checkWindowAndFocus()

            var settled: (axis: ScrollAxis, viewport: ScrollViewport, outcome: ProbeOutcome,
                          step: Int, lines: Int32, motionLimit: Int)?
            for candidate in Self.probeOrder(preferred: axis) {
                let candidateViewport = try viewport(for: candidate, within: baseViewport)
                let initial = try cropped(before, to: candidateViewport)
                let probeStep = max(24, min(56, axisLength(of: initial, along: candidate) / 10))
                try ensureActive()
                let probePoint = currentScrollPoint()
                diagnosticStage = .probeMotion
                try validateCurrentScrollTarget(at: probePoint)
                let probeLines = ScrollDriver.lineDelta(for: probeStep, backingScale: scale)
                try ScrollDriver.sendScroll(axis: candidate, lines: probeLines, at: probePoint)
                let after = try await ScrollCaptureCancellationBoundary.awaitActive {
                    try await self.captureStableWindow(viewport: candidateViewport)
                }
                try ensureActive()
                try checkWindowAndFocus()
                if let outcome = Self.probeOutcome(before: before, after: after,
                                                   viewportPixels: pixelRect(of: candidateViewport),
                                                   axis: candidate,
                                                   preserveCrossAxis: scrollContainer != nil) {
                    let motionLimit = ScrollDriver.maximumLikelyMovement(
                        pixelStep: probeStep, backingScale: scale,
                        viewportLength: axisLength(of: initial, along: candidate))
                    settled = (candidate, candidateViewport, outcome, probeStep, probeLines, motionLimit)
                    break
                }
                // Nothing moved that way. The next axis starts from what the
                // window shows now; when the probe moved nothing at all that is
                // the very frame taken before it.
                before = after
            }
            guard let settled else { throw ScrollDriverError.noMovingContent }
            axis = settled.axis
            assembler = ImageAssembler(axis: axis)
            let (first, probe) = (settled.outcome.first, settled.outcome.probe)
            let probeStep = settled.step
            let probeLines = settled.lines
            let probeMotionLimit = settled.motionLimit
            guard let croppedViewport = settled.viewport.cropped(to: settled.outcome.movingRect,
                                                                 backingScale: scale) else {
                throw ScrollDriverError.scrollAreaUnavailable
            }
            self.viewport = croppedViewport
            assembler.begin(with: first)
            previous = probe
            var requestedStep = max(24, Int(Double(axisLength(of: first)) * 0.60))
            var unmatchedScroll = 0
            /// How far one wheel line moved the page, measured on the probe.
            /// Nil until a probe has been matched, and then the estimate from
            /// points is what steps are planned from.
            var pixelsPerLine: Double?
            /// Whether a full step has matched what the calibration says, so
            /// that lines are known to move the page in proportion — and how
            /// many steps in a row have been placed by the calibration alone.
            var linearityConfirmed = false
            var predictedInARow = 0

            do {
                diagnosticStage = .match
                let match = try FrameMatcher.match(previous: first, current: probe, axis: axis,
                                                   maximumOffset: probeMotionLimit + 24)
                try ensureActive()
                try assembler.append(probe, movement: match.offset)
                pixelsPerLine = ScrollStepPlanner.pixelsPerLine(offset: match.offset, lines: Int(probeLines))
                if let pixelsPerLine {
                    let plan = ScrollStepPlanner.plan(target: requestedStep, pixelsPerLine: pixelsPerLine,
                                                      axisLength: axisLength(of: first), backingScale: scale)
                    Log.capture.info("scroll calibrated · \(Int(pixelsPerLine.rounded()), privacy: .public) px per line · \(plan.lines, privacy: .public) lines per step")
                }
            } catch {
                // The selected scroll view did not yield stable moving content
                // across the probe; keep the initial image for a partial save.
                previous = first
                unmatchedScroll = probeStep
                consecutiveFailures = 1
            }

            while !Task.isCancelled && !stopped {
                // The end of the road is not a failure: what is collected is saved.
                guard Date().timeIntervalSince(startedAt) < 90 else {
                    finish()
                    return
                }
                guard assembler.totalLength < ImageAssembler.maxOutputLength,
                      (axis == .vertical ? first.width : first.height) * assembler.totalLength < ImageAssembler.maxOutputPixels else {
                    finish()
                    return
                }
                guard let oldFrame = previous else { return }
                try checkWindowAndFocus()
                let currentStep = min(requestedStep, max(24, axisLength(of: oldFrame) * 3 / 4))
                let plan = ScrollStepPlanner.plan(target: currentStep, pixelsPerLine: pixelsPerLine,
                                                  axisLength: axisLength(of: oldFrame), backingScale: scale)
                let motionLimit = plan.motionLimit
                let point = currentScrollPoint()
                try ensureActive()
                diagnosticStage = .validateTarget
                try validateCurrentScrollTarget(at: point)
                try ScrollDriver.sendScroll(axis: axis, lines: plan.lines, at: point)
                diagnosticStage = .capture
                let next = try await ScrollCaptureCancellationBoundary.awaitActive {
                    try await self.captureStableViewport(reference: oldFrame)
                }
                try ensureActive()
                try checkWindowAndFocus()

                let looksStationary = meanDifference(oldFrame, next) < 0.006
                /// Whether this is the first attempt at this step: an earlier
                /// failed one has moved the page by a distance nothing here
                /// accounts for.
                let cleanStep = unmatchedScroll == 0
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
                    guard combinedLength <= ImageAssembler.maxOutputLength,
                          crossLength * combinedLength <= ImageAssembler.maxOutputPixels else {
                        finish()
                        return
                    }
                    try ensureActive()
                    try assembler.append(next, movement: match.offset)
                    if cleanStep, let pixelsPerLine,
                       ScrollStepPlanner.confirmsLinearity(offset: match.offset, lines: Int(plan.lines),
                                                           pixelsPerLine: pixelsPerLine) {
                        linearityConfirmed = true
                    } else if cleanStep, pixelsPerLine == nil,
                              let late = ScrollStepPlanner.pixelsPerLine(offset: match.offset,
                                                                         lines: Int(plan.lines)) {
                        // The probe could not be matched — the first screen is
                        // mostly a video, say — so the first step that does match
                        // is what calibrates. Not one that follows a failed
                        // attempt: that distance includes the attempt's.
                        pixelsPerLine = late
                        let latePlan = ScrollStepPlanner.plan(target: requestedStep, pixelsPerLine: late,
                                                              axisLength: axisLength(of: next), backingScale: scale)
                        Log.capture.info("scroll calibrated late · \(Int(late.rounded()), privacy: .public) px per line · \(latePlan.lines, privacy: .public) lines per step")
                    }
                    previous = next
                    zeroMotionCount = 0
                    unmatchedScroll = 0
                    predictedInARow = 0
                    requestedStep = max(24, Int(Double(axisLength(of: next)) * 0.60))
                    consecutiveFailures = 0
                } catch is CancellationError {
                    throw CancellationError()
                } catch FrameMatchError.noReliableMotion where looksStationary {
                    // Ask the matcher before declaring the end. A small final
                    // partial step may have a low whole-frame difference but
                    // still contain a reliable overlap to append.
                    zeroMotionCount += 1
                    consecutiveFailures = 0
                    if zeroMotionCount >= 3 {
                        // Three frames in a row without movement: the end of
                        // the content.
                        finish()
                        return
                    }
                } catch {
                    // Something in the frame changes by itself — a video, an
                    // animation — and the matcher cannot place the step. The
                    // calibration says how far it moved; it is taken at its
                    // word only when the frames do not contradict it and at
                    // least one tile of them agrees, never blind.
                    let undecided = (error as? FrameMatchError == .ambiguousMotion)
                        || (error as? FrameMatchError == .noReliableMotion)
                    if undecided, !looksStationary, let pixelsPerLine,
                       ScrollStepPlanner.mayPredict(pixelsPerLine: pixelsPerLine,
                                                    predictedInARow: predictedInARow,
                                                    unaccountedScroll: unmatchedScroll) {
                        let predicted = ScrollStepPlanner.predictedOffset(lines: Int(plan.lines),
                                                                          pixelsPerLine: pixelsPerLine)
                        let axis = self.axis
                        let searchLimit = motionLimit + 32
                        let verdict = await Task.detached(priority: .userInitiated) {
                            FrameMatcher.verifyPredicted(previous: oldFrame, current: next, axis: axis,
                                                         offset: predicted, searchLimit: searchLimit)
                        }.value
                        try ensureActive()
                        if let verdict,
                           verdict.consistent >= ScrollStepPlanner.tilesRequiredToAgree(
                               linearityConfirmed: linearityConfirmed) {
                            let combinedLength = assembler.totalLength + predicted
                            let crossLength = axis == .vertical ? next.width : next.height
                            guard combinedLength <= ImageAssembler.maxOutputLength,
                                  crossLength * combinedLength <= ImageAssembler.maxOutputPixels else {
                                finish()
                                return
                            }
                            try assembler.append(next, movement: predicted)
                            Log.capture.info("scroll step predicted · \(predicted, privacy: .public) px · \(verdict.consistent, privacy: .public) tiles agree")
                            previous = next
                            zeroMotionCount = 0
                            unmatchedScroll = 0
                            predictedInARow += 1
                            requestedStep = max(24, Int(Double(axisLength(of: next)) * 0.60))
                            consecutiveFailures = 0
                            continue
                        }
                    }
                    consecutiveFailures += 1
                    if consecutiveFailures <= 2 {
                        // Retry from the same stable frame with a smaller probe;
                        // do not append a questionable match.
                        requestedStep = max(12, currentStep / 2)
                        unmatchedScroll += motionLimit
                    } else {
                        pause(reason: LocaleManager.shared.string("Frames couldn't be aligned."))
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
                pause(reason: localizedMessage(for: error))
            }
        }
    }

    private func validateCurrentScrollTarget(at point: CGPoint) throws {
        guard !ownUICovers(point) else { throw ScrollDriver.selectedWindowNotFrontmost() }
        guard scrollContainer != nil else {
            try ScrollDriver.validateSelectedWindow(selection: selection, point: point,
                                                    ignoring: ignoredWindows())
            return
        }
        try ScrollDriver.validateScrollTarget(selection: selection, point: point, container: scrollContainer!,
                                              ignoring: ignoredWindows())
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

    /// A failure with part of the image already collected: the capture stops
    /// and waits for the user — Done saves what there is, ✕ drops it.
    private func pause(reason: String) {
        previous = nil
        onStatus?(.paused(reason: reason))
    }

    /// The whole selected window, as one frame.
    private func captureWindow() async throws -> CaptureFrame {
        try ensureActive()
        let full = try await source.capture(windowID: selection.windowID, scale: scale)
        try ensureActive()
        return full
    }

    private func captureViewport() async throws -> CaptureFrame {
        guard let viewport else { throw ScrollDriverError.scrollAreaUnavailable }
        return try cropped(try await captureWindow(), to: viewport)
    }

    /// The viewport's region of a whole-window frame.
    private func cropped(_ full: CaptureFrame, to viewport: ScrollViewport) throws -> CaptureFrame {
        guard let crop = full.cropped(to: pixelRect(of: viewport)) else {
            throw WindowFrameSourceError.invalidFrame
        }
        return crop
    }

    private func pixelRect(of viewport: ScrollViewport) -> CGRect {
        let points = viewport.cropRectInWindowPoints
        return CGRect(x: points.minX * scale, y: points.minY * scale,
                      width: points.width * scale, height: points.height * scale)
    }

    /// The viewport for one direction. The scrollbar to leave out is the one
    /// along that direction's edge, so it depends on the axis being tried.
    private func viewport(for axis: ScrollAxis, within base: ScrollViewport) throws -> ScrollViewport {
        guard excludeScrollbars else { return base }
        let axScrollbarInset = ScrollDriver.scrollbarInsetPoints(container: scrollContainer,
                                                                  viewport: base.windowRect,
                                                                  axis: axis)
        let reservedPoints = axScrollbarInset ?? Geometry.fallbackScrollbarInsetPoints
        guard let adjusted = base.excludingScrollbar(axis: axis, insetPoints: reservedPoints) else {
            throw ScrollDriverError.scrollAreaUnavailable
        }
        let origin = axScrollbarInset == nil ? "fixed edge reserve" : "AX scrollbar geometry"
        Log.capture.info("scrollbar edge excluded · \(reservedPoints, privacy: .public) points · \(origin, privacy: .public)")
        return adjusted
    }

    /// The probe's second look, still the whole window. Settled is judged on
    /// the candidate viewport — the part that is going to be stitched — so a
    /// title bar or a fading scrollbar does not keep it waiting.
    private func captureStableWindow(viewport candidate: ScrollViewport) async throws -> CaptureFrame {
        var latest = try await captureWindow()
        let deadline = Date().addingTimeInterval(1.8)
        while Date() < deadline && !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(140))
            let next = try await captureWindow()
            let change = meanDifference(try cropped(latest, to: candidate), try cropped(next, to: candidate))
            latest = next
            if change < 0.003 { return latest }
        }
        return latest
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
            throw WindowFrameSourceError.captureFailed(LocaleManager.shared.string("The window size changed."))
        }
        guard abs(Self.backingScale(for: now) - scale) < 0.01 else {
            throw WindowFrameSourceError.captureFailed(LocaleManager.shared.string("The display scale changed."))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == selection.processID else {
            throw WindowFrameSourceError.captureFailed(LocaleManager.shared.string("The window moved to the background."))
        }
    }

    private func waitForTargetFocus() async throws {
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline && !Task.isCancelled {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == selection.processID {
                do {
                    try ScrollDriver.validateSelectedWindow(selection: selection, point: selection.clickPoint,
                                                        ignoring: ignoredWindows())
                    return
                } catch {
                    // Wait briefly for activation to expose the exact selected
                    // window; a covered point is never sent a scroll event.
                }
            }
            try await Task.sleep(for: .milliseconds(80))
        }
        throw WindowFrameSourceError.captureFailed(LocaleManager.shared.string("The window moved to the background."))
    }

    private func currentScrollPoint() -> CGPoint {
        guard let viewport, let bounds = ScrollDriver.currentWindowBounds(selection.windowID) else {
            return selection.clickPoint
        }
        return CGPoint(x: bounds.minX + viewport.relativeScrollPoint.x,
                       y: bounds.minY + viewport.relativeScrollPoint.y)
    }

    private func axisLength(of frame: CaptureFrame, along axis: ScrollAxis? = nil) -> Int {
        (axis ?? self.axis) == .vertical ? frame.height : frame.width
    }

    private func localizedMessage(for error: Error) -> String {
        guard let matchError = error as? FrameMatchError else { return error.localizedDescription }
        let key: String
        switch matchError {
        case .noReliableMotion: key = "The area doesn't scroll. Click inside the page or table and start again."
        case .ambiguousMotion: key = "The content is too uniform to align. The capture stopped to avoid a broken image."
        case .crossAxisMotion: key = "The content moved sideways. Don't move the window during the capture."
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

    /// The directions to probe, in order: the one asked for, then the other. A
    /// page that does not scroll the way the picker said may scroll the other
    /// way, and neither answering is the "does not scroll" of the alert.
    nonisolated static func probeOrder(preferred: ScrollAxis) -> [ScrollAxis] {
        [preferred, preferred == .vertical ? .horizontal : .vertical]
    }

    /// What a probe in one direction found.
    struct ProbeOutcome {
        /// The frame before the probe and the one after, cut to the part that
        /// moved.
        let first: CaptureFrame
        let probe: CaptureFrame
        /// That part, in pixels of the viewport's crop.
        let movingRect: CGRect
    }

    /// Cuts two whole-window frames to a direction's viewport and finds what
    /// moved between them. Nil when nothing did in that direction. Taking
    /// whole-window frames is what lets one starting frame serve either axis.
    nonisolated static func probeOutcome(before: CaptureFrame, after: CaptureFrame,
                                          viewportPixels: CGRect, axis: ScrollAxis,
                                          preserveCrossAxis: Bool) -> ProbeOutcome? {
        guard let initial = before.cropped(to: viewportPixels),
              let moved = after.cropped(to: viewportPixels),
              let movingRect = movingContentRect(before: initial, after: moved, axis: axis,
                                                 preserveCrossAxis: preserveCrossAxis),
              let first = initial.cropped(to: movingRect),
              let probe = moved.cropped(to: movingRect)
        else { return nil }
        return ProbeOutcome(first: first, probe: probe, movingRect: movingRect)
    }

    /// Finds the 2D bounding box of pixels that changed between the probe pair.
    /// This works for an AX-resolved viewport and for a whole-window fallback,
    /// where fixed sidebars/headers must be excluded before stitching.
    nonisolated static func movingContentRect(before: CaptureFrame, after: CaptureFrame,
                                               axis: ScrollAxis, preserveCrossAxis: Bool = false) -> CGRect? {
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
        guard let (p0, p1) = primary, p1 - p0 >= primaryLength / 3 else { return nil }
        let c0: Int, c1: Int
        if preserveCrossAxis {
            c0 = 0
            c1 = crossLength
        } else {
            guard let (activeStart, activeEnd) = cross,
                  activeEnd - activeStart >= max(80, crossLength / 3) else { return nil }
            c0 = activeStart
            c1 = activeEnd
        }
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
        guard let display = displays.first(where: { CGDisplayBounds($0).contains(center) }) else { return 1 }
        if let mode = CGDisplayCopyDisplayMode(display),
           let scale = backingScale(pixelWidth: mode.pixelWidth, pointWidth: mode.width) {
            return scale
        }
        return NSScreen.screens.first { $0.displayID == display }?.backingScaleFactor ?? 1
    }

    /// What to do about Accessibility: macOS's own prompt the first time, our
    /// alert every time after. Never both at once.
    nonisolated static func accessibilityPlan(promptedBefore: Bool) -> (prompt: Bool, alertIfDenied: Bool) {
        (prompt: !promptedBefore, alertIfDenied: promptedBefore)
    }

    /// Backing pixels per point of a display mode. `CGDisplayPixelsWide`
    /// counts points on a Retina display, so it reads 2x as 1x.
    nonisolated static func backingScale(pixelWidth: Int, pointWidth: Int) -> CGFloat? {
        guard pixelWidth > 0, pointWidth > 0 else { return nil }
        return max(1, CGFloat(pixelWidth) / CGFloat(pointWidth))
    }
}
