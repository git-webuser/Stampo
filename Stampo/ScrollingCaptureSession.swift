import AppKit
import ApplicationServices
import ScreenCaptureKit
import os

/// What the notch strip shows while a scrolling capture runs.
enum ScrollCaptureStatus: Equatable {
    case capturing
    /// The capture waits — the user paused it, or something stopped it — and the
    /// strip offers to resume it, to save what is collected, or to drop it.
    /// `announce` says whether a toast tells the user it stopped: it does not
    /// when they paused it themselves.
    case paused(announce: Bool)
    /// Save was pressed, or a limit was reached: the file is being written.
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
    /// Nothing could be collected, and the reason is none of the user's
    /// business: the window is to be captured as it stands instead, the way
    /// the Window mode does it.
    var onWindowScreenshotInstead: (() -> Void)?

    private let selection: WindowPickerSelection
    /// The direction asked for until the probe has settled, the direction the
    /// capture actually goes after it: a page that does not scroll that way
    /// may scroll the other.
    private var axis: ScrollAxis
    private let excludeScrollbars: Bool
    /// Where the capture stops and saves, in pixels along the scroll, and
    /// whether it drops to 1x there and goes on instead (see `makeRoom`).
    private let lengthLimit: Int
    private let shrinkToFit: Bool
    private let activateSelectedWindow: @MainActor (WindowPickerSelection) throws -> Void
    /// Whether Stampo's own visible UI (the notch panel) is over a Quartz
    /// point. Own windows are not in the frontmost-window check.
    private let ownUICovers: @MainActor (CGPoint) -> Bool
    /// Window numbers of ours that do not count as covering the page: the
    /// notch panel's. Every other window of Stampo over the point does.
    private let ignoredWindows: @MainActor () -> Set<CGWindowID>
    private let source = WindowFrameSource()
    private var escapeToken: UUID?
    /// Watches for the user's own input once the capture scrolls by itself:
    /// while it runs, any of it pauses the capture; while it is paused, it is
    /// written down in `pauseLedger`, to find the place again.
    private var inputMonitor: ScrollInputMonitor?
    /// Paused — by the user, by their input, or by a failure — and waiting for
    /// them: Save, ✕, or resume.
    private var paused = false
    private var pausedAt = Date()
    private var pauseLedger = UserScrollLedger()
    /// A wheel event has been sent and what came of it not yet dealt with: if a
    /// pause cuts in here, the page is somewhere between the places the frames know.
    private var stepInFlight = false
    /// Time that does not count against the 20 s without progress: waiting for
    /// the pointer, and the capture paused. Summed over the whole capture;
    /// what has passed since the last headway is the difference with
    /// `idleAtProgress`.
    private var idleSeconds: TimeInterval = 0
    /// When the capture last made headway — a step into the image, the queue
    /// laid, a step put in the queue — and how much idle time there was by then.
    private var lastProgress = Date()
    private var idleAtProgress: TimeInterval = 0
    /// Hiccups waited out since the last headway (`ScrollInterference`), and
    /// whether the log has said that the scroll area is no longer found under
    /// the point.
    private var recoveriesWithoutProgress = 0
    private var loggedAreaFallback = false
    private var task: Task<Void, Never>?
    private var stopped = false
    private var diagnosticStage: DiagnosticStage = .raiseWindow
    private var viewport: ScrollViewport?
    private var scrollContainer: AXUIElement?
    private var scale: CGFloat = 1
    private var assembler: ImageAssembler
    private var previous: CaptureFrame?
    private var zeroMotionCount = 0
    /// The frames and steps of this capture on disk, when a Debug build is asked
    /// to keep them (`ScrollFrameDump`), and which attempt at a step is being made.
    private var dump: ScrollFrameDump?
    private var stepNumber = 0
    /// Steps placed by the calibration alone, waiting for one the matcher places.
    private var temporary = TemporarySteps()
    /// Tiles seen standing still while the page moved: fixed to the viewport,
    /// and no proof, by standing, that the page has stopped.
    private var pinnedTiles = Set<Int>()
    /// Steps in a row that would not match.
    private var consecutiveFailures = 0

    // What the steps carry from one to the next. Instance state rather than the
    // locals of one long function, so that a pause can end the task and a resume
    // start a new one that goes on from here.
    private var requestedStep = 24
    /// How much the page has moved that no step accounts for: the probe that
    /// could not be matched. Zero otherwise — a retry goes back what it moved.
    private var unmatchedScroll = 0
    /// How far one wheel line moved the page, measured on the probe. Nil until
    /// a probe has been matched, and then the estimate from points is what
    /// steps are planned from.
    private var pixelsPerLine: Double?
    /// Whether a full step has matched what the calibration says, so that lines
    /// are known to move the page in proportion.
    private var linearityConfirmed = false

    init(selection: WindowPickerSelection, axis: ScrollAxis,
         excludeScrollbars: Bool = true,
         lengthLimit: Int = ScrollLengthLimit.default,
         shrinkToFit: Bool = false,
         activateSelectedWindow: (@MainActor (WindowPickerSelection) throws -> Void)? = nil,
         ownUICovers: @escaping @MainActor (CGPoint) -> Bool = { _ in false },
         ignoredWindows: @escaping @MainActor () -> Set<CGWindowID> = { [] }) {
        self.selection = selection
        self.axis = axis
        self.excludeScrollbars = excludeScrollbars
        self.lengthLimit = lengthLimit
        self.shrinkToFit = shrinkToFit
        self.activateSelectedWindow = activateSelectedWindow ?? { selected in
            try ScrollDriver.raiseSelectedWindow(selected, ignoring: ignoredWindows())
        }
        self.ownUICovers = ownUICovers
        self.ignoredWindows = ignoredWindows
        self.assembler = ImageAssembler(axis: axis, maxLength: lengthLimit)
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
        // The capture is over before a step the matcher places has come to
        // carry the waiting ones into the image: what they stood for is not in it.
        let dropped = temporary.discard()
        if dropped > 0 {
            Log.capture.notice("scroll queue dropped \(dropped, privacy: .public)")
            dump?.step("   queue dropped \(dropped)")
        }
        Log.capture.notice("scroll capture saving · \(self.assembler.totalLength, privacy: .public) px · \(self.assembler.strips.count, privacy: .public) strips · \(self.stepNumber, privacy: .public) steps")
        do {
            let image = try assembler.makeImage()
            dump?.save(image, as: "final")
            dump?.step("final \(image.width)x\(image.height)")
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

    private func startInputGuard() {
        guard inputMonitor == nil else { return }
        let monitor = ScrollInputMonitor(onEvent: { [weak self] event in self?.handleUserInput(event) })
        monitor.start()
        inputMonitor = monitor
    }

    private func stopInputGuard() {
        inputMonitor?.stop()
        inputMonitor = nil
    }

    /// The user did something while the capture scrolled by itself. Running, any
    /// hand on the page pauses it at once — the step in flight is not to be
    /// trusted — and waits: resume, Save keeps what is collected, ✕ drops it.
    /// Paused, it is only written down: the page may have moved.
    private func handleUserInput(_ event: ScrollInputGuard.Event) {
        guard !stopped, inputMonitor != nil else { return }
        if paused {
            pauseLedger.record(event, axis: axis)
            return
        }
        // The tail of a gesture that began before the capture did is inertia,
        // not a hand on the page.
        guard !event.isMomentum else { return }
        switch ScrollInputGuard.outcome(of: ScrollInputGuard.response(to: event.kind, userData: event.userData),
                                        hasCollected: !assembler.strips.isEmpty) {
        case .ignore:
            return
        case .windowScreenshot:
            Log.capture.notice("scroll capture interrupted before the first frame")
            windowScreenshotInstead()
        case .pause:
            pause(announce: true)
            pauseLedger.record(event, axis: axis)
        }
    }

    // MARK: Pause and resume

    /// The ring on the strip, clicked: pauses a capture that runs, resumes one
    /// that waits.
    func togglePause() {
        guard !stopped else { return }
        if paused { resume() } else { pause(announce: false) }
    }

    /// Waiting for the user: Save keeps what there is, ✕ drops it, and the play
    /// sign goes on. Nothing is forgotten — the last frame, the calibration, the
    /// pinned tiles, the steps waiting — except the step in flight, which is cut
    /// short.
    private func pause(announce: Bool) {
        guard !paused, !stopped else { return }
        paused = true
        pausedAt = Date()
        pauseLedger = UserScrollLedger()
        task?.cancel()
        task = nil
        Log.capture.notice("scroll capture paused · \(announce ? "with a toast" : "by the user", privacy: .public) · \(self.assembler.totalLength, privacy: .public) px collected")
        dump?.step("paused \(announce ? "with a toast" : "by the user")")
        onStatus?(.paused(announce: announce))
    }

    private func resume() {
        guard paused, !stopped else { return }
        paused = false
        idleSeconds += Date().timeIntervalSince(pausedAt)
        // The window comes forward and the page is looked for: that takes
        // its own seconds, which a pause near the end of the twenty must not
        // leave too few of.
        noteProgress()
        Log.capture.notice("scroll capture resumes")
        dump?.step("resumed")
        onStatus?(.capturing)
        task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.resumeRun()
        }
    }

    /// The capture after a pause: the window forward, the page found, the steps
    /// on from there. Before the first strip there is nothing to find, and the
    /// capture starts over.
    private func resumeRun() async {
        guard !assembler.strips.isEmpty else {
            await run()
            return
        }
        await guarded {
            try self.ensureActive()
            self.diagnosticStage = .raiseWindow
            try self.activateSelectedWindow(self.selection)
            try await self.waitForTargetFocus()
            try self.ensureActive()
            try self.checkWindowAndFocus()
            try await self.continueFromHere()
        }
    }

    /// Where the page is, compared with the last frame; the page moved back to
    /// it, or the frame it stands at laid on. False when it cannot be found.
    private func findThePlace() async throws -> Bool {
        guard let last = previous else { return true }
        let ledger = pauseLedger
        guard ScrollResume.needsLooking(ledger: ledger, stepWasInFlight: stepInFlight) else {
            return true
        }
        let userMovement = ledger.pageMovement(scale: scale, pixelsPerLine: pixelsPerLine)
        var undone = false
        for _ in 0..<4 {
            let now = try await ScrollCaptureCancellationBoundary.awaitActive {
                try await self.captureStableViewport(reference: last)
            }
            try ensureActive()
            try checkWindowAndFocus()
            let axis = self.axis
            let finding = await Task.detached(priority: .userInitiated) {
                ScrollPlaceFinding.find(last: last, now: now, axis: axis)
            }.value
            try ensureActive()
            let action = ScrollResume.action(finding: finding, userMovement: userMovement, undone: undone)
            Log.capture.notice("scroll place after the pause · \(String(describing: finding), privacy: .public) → \(String(describing: action), privacy: .public)")
            dump?.step("place \(finding) → \(action)")
            switch action {
            case .goOn:
                stepInFlight = false
                return true
            case .lay(let movement):
                guard try lay(now, movement: movement) != nil else {
                    finish()
                    return true
                }
                previous = now
                stepInFlight = false
                zeroMotionCount = 0
                consecutiveFailures = 0
                unmatchedScroll = 0
                return true
            case .scrollForward(let pixels):
                try await scroll(pixels: pixels, forward: true)
            case .undoUser(let pixels):
                undone = true
                // They scrolled toward the end by `pixels`: it goes back by as much.
                try await scroll(pixels: abs(pixels), forward: pixels < 0)
            case .giveUp:
                return false
            }
        }
        return false
    }

    /// The page moved by about `pixels`, by wheel lines in events of no more
    /// than ten, and a look once it has settled.
    private func scroll(pixels: Int, forward: Bool) async throws {
        var remaining = ScrollResume.lines(forPixels: pixels, pixelsPerLine: pixelsPerLine, scale: scale)
        let point = currentScrollPoint()
        stepInFlight = true
        while remaining > 0 {
            try ensureActive()
            diagnosticStage = .validateTarget
            try validateCurrentScrollTarget(at: point)
            let lines = min(remaining, Int(ScrollResume.linesPerEvent))
            try ScrollDriver.sendScroll(axis: axis, lines: Int32(lines), backwards: !forward, at: point)
            remaining -= lines
            try await Task.sleep(for: .milliseconds(60))
        }
    }

    /// Lays a frame that is `movement` pixels along from the last frame into the
    /// image — first the steps that waited for one the matcher placed. Returns
    /// how many of those there were, or nil when the image has no room for them.
    private func lay(_ frame: CaptureFrame, movement: Int) throws -> Int? {
        let waiting = temporary.take()
        for step in waiting {
            guard makeRoom(for: step.movement) else {
                Log.capture.notice("scroll queue only partly laid · the image is full")
                return nil
            }
            try assembler.append(step.frame, movement: step.movement)
        }
        guard makeRoom(for: movement) else { return nil }
        try ensureActive()
        try assembler.append(frame, movement: movement)
        noteProgress()
        return waiting.count
    }

    /// The capture has made headway: the seconds without it start again.
    private func noteProgress() {
        lastProgress = Date()
        idleAtProgress = idleSeconds
        recoveriesWithoutProgress = 0
    }

    /// The pointer is off the page or on the strip: hold the next step.
    private func pointerIsAway() -> Bool {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.screens.first?.frame.height ?? 0
        let pointer = ScrollInputGuard.quartzPoint(fromAppKit: NSEvent.mouseLocation, primaryHeight: primaryHeight)
        let window = ScrollDriver.currentWindowBounds(selection.windowID) ?? selection.bounds
        return ScrollInputGuard.shouldWait(pointer: pointer, window: window, overOwnUI: ownUICovers(pointer))
    }

    /// Holds still while the pointer is away. The time does not count towards the
    /// seconds without progress.
    private func waitForPointer() async throws {
        guard pointerIsAway() else { return }
        let began = Date()
        Log.capture.notice("scroll waits for the pointer")
        while pointerIsAway() {
            try ensureActive()
            try await Task.sleep(for: .milliseconds(100))
        }
        idleSeconds += Date().timeIntervalSince(began)
        Log.capture.notice("scroll goes on, the pointer is back")
    }

    private func cleanup() {
        stopInputGuard()
        if let escapeToken { TransientHotkeyCenter.escape.remove(escapeToken) }
        escapeToken = nil
        task = nil
        scrollContainer = nil
    }

    private func releaseCaptureBuffers() {
        previous = nil
        temporary.discard()
        assembler.reset()
    }

    private func ensureActive() throws {
        guard !Task.isCancelled, !stopped else { throw CancellationError() }
    }

    func run() async {
        await guarded {
            try await self.prepare()
            try await self.stepLoop()
        }
    }

    /// One stretch of the capture, with what goes wrong in it dealt with: a
    /// cancellation ends it quietly; any other failure with nothing collected
    /// ends in an alert or the window's screenshot, and with something
    /// collected in a pause.
    private func guarded(_ body: () async throws -> Void) async {
        do {
            try await body()
        } catch is CancellationError {
            return
        } catch {
            if !stopped {
                logFailure(error)
                guard !assembler.strips.isEmpty else {
                    failBeforeTheFirstFrame(error)
                    return
                }
                // A hiccup — a notification over the scroll point, the window
                // list stumbling for an instant — is waited out, and the capture
                // goes on from where the page is.
                if let interference = ScrollInterference.classify(error),
                   recoveriesWithoutProgress < ScrollInterference.maxWithoutProgress {
                    recoveriesWithoutProgress += 1
                    let cleared: Bool
                    do { cleared = try await waitOut(interference) } catch { return }
                    if cleared {
                        pauseLedger = UserScrollLedger()
                        await guarded { try await self.continueFromHere() }
                        return
                    }
                }
                // Whatever it was — the window sent to the back, the scroll area
                // replaced, a hiccup that did not pass — the log has it; the
                // toast only says the capture stopped.
                pause(announce: true)
            }
        }
    }

    /// Waits for a hiccup to pass, looking again every quarter second, for as
    /// long as it is worth waiting (`ScrollInterference.patience`). The time
    /// does not count towards the seconds without progress. Whether it passed.
    private func waitOut(_ interference: ScrollInterference) async throws -> Bool {
        let began = Date()
        Log.capture.notice("scroll waits: \(interference.logText, privacy: .public)")
        dump?.step("   waits: \(interference.logText)")
        while true {
            try ensureActive()
            let waited = Date().timeIntervalSince(began)
            let clear: Bool
            switch interference {
            case .pointCovered: clear = (try? validateCurrentScrollTarget(at: currentScrollPoint())) != nil
            case .windowGlitch: clear = (try? checkWindowAndFocus()) != nil
            }
            switch interference.verdict(clear: clear, waited: waited) {
            case .goOn:
                idleSeconds += waited
                Log.capture.notice("scroll goes on after \(String(format: "%.1f", waited), privacy: .public) s")
                dump?.step("   goes on after \(String(format: "%.1f", waited)) s")
                return true
            case .pause:
                idleSeconds += waited
                Log.capture.notice("scroll waited \(String(format: "%.1f", waited), privacy: .public) s: \(interference.logText, privacy: .public)")
                return false
            case .wait:
                try await Task.sleep(for: .seconds(ScrollInterference.pollInterval))
            }
        }
    }

    /// Where the page is, and the steps on from there: after a resume, or after
    /// a hiccup that has passed.
    private func continueFromHere() async throws {
        guard try await findThePlace() else {
            Log.capture.notice("scroll place not found after the pause · saved what was collected")
            dump?.step("place not found → saved")
            finish()
            return
        }
        try await stepLoop()
    }

    /// From the window raised to the probe matched: the first strip is in, and
    /// the step loop can start.
    private func prepare() async throws {
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
                Log.capture.notice("scroll capture viewport fallback: AX target identity was incomplete")
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
            Log.capture.notice("scroll capture viewport fallback: AX hit did not resolve a suitable scroll container")
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
        dump = ScrollFrameDump.begin()
        dump?.save(before, as: "00-before")

        // From here the capture scrolls on its own, and a hand on the page
        // is the one thing that spoils it.
        startInputGuard()

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
        assembler = ImageAssembler(axis: axis, maxLength: lengthLimit)
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
        noteProgress()
        previous = probe
        dump?.save(probe, as: "00-probe")
        Log.capture.notice("scroll probe settled · \(self.axis == .vertical ? "vertical" : "horizontal", privacy: .public) · \(probeLines, privacy: .public) lines · limit \(probeMotionLimit, privacy: .public) px · scale \(self.scale, privacy: .public)")
        requestedStep = max(24, Int(Double(axisLength(of: first)) * 0.60))
        unmatchedScroll = 0
        pixelsPerLine = nil
        linearityConfirmed = false

        do {
            diagnosticStage = .match
            let match = try FrameMatcher.match(previous: first, current: probe, axis: axis,
                                               maximumOffset: probeMotionLimit + 24)
            try ensureActive()
            try assembler.append(probe, movement: match.offset)
            notePinned(match.standing)
            pixelsPerLine = ScrollStepPlanner.pixelsPerLine(offset: match.offset, lines: Int(probeLines))
            if let pixelsPerLine {
                let plan = ScrollStepPlanner.plan(target: requestedStep, pixelsPerLine: pixelsPerLine,
                                                  axisLength: axisLength(of: first), backingScale: scale)
                Log.capture.notice("scroll calibrated · \(Int(pixelsPerLine.rounded()), privacy: .public) px per line · \(plan.lines, privacy: .public) lines per step")
            }
            recordStep(0, "lines=\(probeLines) maximumOffset=\(probeMotionLimit + 24) · match \(match.offset) px · confidence \(Self.percent(match.confidence)) · regions \(match.independentRegions) → calibrated")
        } catch {
            recordStep(0, "lines=\(probeLines) maximumOffset=\(probeMotionLimit + 24) · \(error) → probe not matched")
            // The selected scroll view did not yield stable moving content
            // across the probe; keep the initial image for a partial save.
            previous = first
            unmatchedScroll = probeStep
            consecutiveFailures = 1
        }
    }

    /// The steps, one after the other, until the end of the page, a limit, or a
    /// stop. Everything that goes from one step to the next is instance state,
    /// so that a pause can end this and a resume start it again.
    private func stepLoop() async throws {
        while !Task.isCancelled && !stopped {
            // The pointer on the strip or off the page: the user is reaching
            // for a button, and a step sent now would be wasted. Wait.
            try await waitForPointer()
            // The end of the road is not a failure: what is collected is saved.
            // There is no limit on how long a capture takes, only on how long it
            // goes without headway; waiting and pauses are not time without it.
            guard !ScrollProgressTimeout.isOver(lastProgress: lastProgress, now: Date(),
                                                idle: idleSeconds - idleAtProgress) else {
                recordStep("saved: \(Int(ScrollProgressTimeout.seconds)) s without progress")
                finish()
                return
            }
            guard makeRoom(for: 1) else {
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
            stepInFlight = true
            try ScrollDriver.sendScroll(axis: axis, lines: plan.lines, at: point)
            diagnosticStage = .capture
            let next = try await ScrollCaptureCancellationBoundary.awaitActive {
                try await self.captureStableViewport(reference: oldFrame)
            }
            try ensureActive()
            try checkWindowAndFocus()
            stepNumber += 1
            dump?.save(next, as: String(format: "%02ld-step", stepNumber))

            /// Whether this is the first attempt at this step: an earlier
            /// failed one has moved the page by a distance nothing here
            /// accounts for.
            let cleanStep = unmatchedScroll == 0
            let maximumOffset = motionLimit + unmatchedScroll + 32
            let head = "lines=\(plan.lines) motionLimit=\(motionLimit) maximumOffset=\(maximumOffset)"
                + " difference=\(String(format: "%.4f", meanDifference(oldFrame, next)))"
            do {
                diagnosticStage = .match
                let axis = self.axis
                let match = try await ScrollCaptureCancellationBoundary.awaitActive {
                    try await Task.detached(priority: .userInitiated) {
                        try FrameMatcher.match(previous: oldFrame, current: next, axis: axis,
                                               maximumOffset: maximumOffset)
                    }.value
                }
                try ensureActive()
                // The steps that waited for this one go into the image first.
                guard let waiting = try lay(next, movement: match.offset) else {
                    finish()
                    return
                }
                notePinned(match.standing)
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
                    Log.capture.notice("scroll calibrated late · \(Int(late.rounded()), privacy: .public) px per line · \(latePlan.lines, privacy: .public) lines per step")
                }
                let queue = waiting == 0 ? "" : " · queue appended \(waiting)"
                recordStep("\(head) · match \(match.offset) px · confidence \(Self.percent(match.confidence)) · regions \(match.independentRegions)\(queue) → added")
                previous = next
                zeroMotionCount = 0
                unmatchedScroll = 0
                requestedStep = max(24, Int(Double(axisLength(of: next)) * 0.60))
                consecutiveFailures = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The matcher cannot place the step. Why is a question for
                // the frames, asked once: which tiles stand still, and, when
                // the calibration says how far the page should have moved,
                // which tiles bear that out.
                let undecided = ScrollStepDecision.isUndecided(error)
                let expected: Int? = undecided && cleanStep
                    ? pixelsPerLine.map { ScrollStepPlanner.predictedOffset(lines: Int(plan.lines), pixelsPerLine: $0) }
                    : nil
                var evidence: FrameMatcher.StepEvidence?
                if undecided {
                    let axis = self.axis
                    let searchLimit = motionLimit + 32
                    evidence = await Task.detached(priority: .userInitiated) {
                        FrameMatcher.evidence(previous: oldFrame, current: next, axis: axis,
                                              offset: expected, searchLimit: searchLimit)
                    }.value
                    try ensureActive()
                }
                let unpinned = ScrollStepDecision.provingStop(standing: evidence?.standing ?? [],
                                                              pinned: pinnedTiles)
                let required = ScrollStepPlanner.tilesRequiredToAgree(linearityConfirmed: linearityConfirmed)
                let decision = ScrollStepDecision.decide(.init(
                    undecided: undecided, canExpect: expected != nil,
                    consistent: evidence?.consistent ?? 0, against: evidence?.against ?? 0,
                    contradicted: evidence?.contradicted ?? false, required: required,
                    unpinnedStanding: unpinned, queued: temporary.count))
                let said = expected.map {
                    "expected \($0) px · \(evidence?.consistent ?? 0) tiles agree, \(evidence?.against ?? 0) against, \(required) needed"
                        + (evidence?.contradicted == true ? ", contradicted" : "")
                } ?? (!undecided ? "not to be predicted"
                      : pixelsPerLine == nil ? "no calibration"
                      : "step not clean (\(unmatchedScroll) px unaccounted)")
                let standing = "\(unpinned) unpinned middle tiles stand"
                switch decision {
                case .stationary:
                    zeroMotionCount += 1
                    consecutiveFailures = 0
                    recordStep("\(head) · \(error) · \(said) → stop: \(standing), page not moving \(zeroMotionCount) of 3")
                    if zeroMotionCount >= 3 {
                        // Three steps in a row proved without movement: the
                        // end of the content.
                        finish()
                        return
                    }
                case .temporary(let confirmed):
                    // Not placed by the frames: placed where the calibration
                    // says, and kept apart until a step the matcher does
                    // place carries it into the image.
                    temporary.add(next, movement: expected ?? 0, confirmed: confirmed)
                    noteProgress()
                    recordStep("\(head) · \(error) · \(said) · \(standing) → temporary (\(confirmed ? "confirmed" : "unconfirmed")), queue \(temporary.count)")
                    previous = next
                    zeroMotionCount = 0
                    unmatchedScroll = 0
                    requestedStep = max(24, Int(Double(axisLength(of: next)) * 0.60))
                    consecutiveFailures = 0
                case .finish:
                    recordStep("\(head) · \(error) · \(said) → saved: \(temporary.count) steps wait for a confirmation")
                    finish()
                    return
                case .retry:
                    consecutiveFailures += 1
                    guard consecutiveFailures <= 2 else {
                        // A video, an animation, a section that stays where
                        // it is: whatever it is, the steps will not line up,
                        // and what is collected is what there is. The user
                        // wanted a screenshot, not an explanation.
                        recordStep("\(head) · \(error) · \(said) → saved: steps would not match")
                        Log.capture.notice("scroll steps would not match · saved what was collected")
                        finish()
                        return
                    }
                    // Back to where the step began, then half of it from there.
                    recordStep("\(head) · \(error) · \(said) · \(standing) → retry \(consecutiveFailures) of 2, back \(plan.lines) lines")
                    requestedStep = max(12, currentStep / 2)
                    // Only this step's lines are undone: a probe that moved
                    // the page unmatched still has to be allowed for.
                    try await returnPage(by: plan.lines, at: point, reference: oldFrame)
                }
            }
            // The step is dealt with: a pause from here on cuts nothing short.
            stepInFlight = false
        }
    }

    /// Whether `movement` more pixels fit under the limit. At the limit, with
    /// shrink-to-fit on and the frames at more than 1x, the image drops to half
    /// resolution — once — and has room for as much again; otherwise there is
    /// none, and the capture saves what it has.
    private func makeRoom(for movement: Int) -> Bool {
        // The limit chosen, or less if the image would pass the memory ceiling
        // at this width — which is read again after a shrink, when it is half
        // as wide.
        switch ScrollLengthLimit.action(lengthAfterAdding: assembler.lengthAfterAdding(movement),
                                        limit: assembler.effectiveLimit, shrinkToFit: shrinkToFit,
                                        frameScale: scale, alreadyShrunk: assembler.isShrunk) {
        case .fits: return true
        case .stop: return false
        case .shrink:
            let at = assembler.totalLength
            assembler.shrinkToHalf()
            Log.capture.notice("scroll shrink to 1x at \(at, privacy: .public) px")
            return assembler.lengthAfterAdding(movement) <= assembler.effectiveLimit
        }
    }

    private func validateCurrentScrollTarget(at point: CGPoint) throws {
        guard !ownUICovers(point) else { throw ScrollDriver.selectedWindowNotFrontmost() }
        guard let container = scrollContainer else {
            try ScrollDriver.validateSelectedWindow(selection: selection, point: point,
                                                    ignoring: ignoredWindows())
            return
        }
        do {
            try ScrollDriver.validateScrollTarget(selection: selection, point: point, container: container,
                                                  ignoring: ignoredWindows())
        } catch {
            guard ScrollInterference.fallsBackToWindowCheck(error, hasCollected: !assembler.strips.isEmpty) else {
                throw error
            }
            // The window is where it was and on top at the point — that is
            // checked first — but Accessibility no longer finds the scroll area
            // under it: an embedded demo, another column of a browser. A wheel
            // event goes to whatever is there; if it does not scroll, the pixels
            // say so. Before the first strip the area is what the capture rests
            // on, and the capture stops as it did.
            if !loggedAreaFallback {
                loggedAreaFallback = true
                Log.capture.notice("scroll AX area not under the point · window check")
                dump?.step("   AX area not under the point · window check")
            }
            try ScrollDriver.validateSelectedWindow(selection: selection, point: point,
                                                    ignoring: ignoredWindows())
        }
    }

    /// The page back where a step that would not match began: the same lines,
    /// the other way, and a look at it once it has settled — so that the
    /// retry's half step starts from a place the frames know, and the distance
    /// the failed step moved is not left for the matcher to search through.
    private func returnPage(by lines: Int32, at point: CGPoint, reference: CaptureFrame) async throws {
        try ensureActive()
        diagnosticStage = .validateTarget
        try validateCurrentScrollTarget(at: point)
        try ScrollDriver.sendScroll(axis: axis, lines: lines, backwards: true, at: point)
        diagnosticStage = .capture
        // Settled before the next step is sent, so that the two do not run
        // into each other while the page still glides back.
        let back = try await ScrollCaptureCancellationBoundary.awaitActive {
            try await self.captureStableViewport(reference: reference)
        }
        try ensureActive()
        try checkWindowAndFocus()
        dump?.save(back, as: String(format: "%02ld-back", stepNumber))
    }

    /// Remembers the tiles that stood still in a step that moved the page.
    private func notePinned(_ standing: Set<Int>) {
        let added = standing.subtracting(pinnedTiles)
        guard !added.isEmpty else { return }
        pinnedTiles.formUnion(added)
        let tiles = added.sorted().map(String.init).joined(separator: ",")
        Log.capture.notice("scroll pinned tiles \(tiles, privacy: .public)")
        dump?.step("   pinned tiles \(tiles)")
    }

    /// One line about an attempt at a step, for the log — `.notice`, which
    /// macOS keeps; `.info` is gone in minutes — and for `steps.txt` of a dump.
    private func recordStep(_ details: String) {
        recordStep(stepNumber, details)
    }

    private func recordStep(_ number: Int, _ details: String) {
        let line = String(format: "%02ld ", number) + details
        Log.capture.notice("scroll step \(line, privacy: .public)")
        dump?.step(line)
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// A failure with nothing collected yet. The user asked for a screenshot,
    /// so unless the way to one is closed — see `ScrollStartFailure` — they get
    /// the window as it stands.
    private func failBeforeTheFirstFrame(_ error: Error) {
        switch ScrollStartFailure.response(to: error) {
        case .alert:
            presentFailure(error)
            cancel()
        case .windowScreenshot:
            windowScreenshotInstead()
        }
    }

    /// The scrolling capture ends here and the service takes the window's
    /// screenshot in its place. Without one to ask, it is a cancellation.
    private func windowScreenshotInstead() {
        guard !stopped else { return }
        guard let onWindowScreenshotInstead else {
            cancel()
            return
        }
        stopped = true
        task?.cancel()
        cleanup()
        releaseCaptureBuffers()
        Log.capture.notice("scroll capture gave way to the window screenshot")
        dump?.step("window screenshot instead")
        onWindowScreenshotInstead()
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
        Log.capture.notice("scrollbar edge excluded · \(reservedPoints, privacy: .public) points · \(origin, privacy: .public)")
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
            throw ScrollDriverError.windowSizeChanged
        }
        guard abs(Self.backingScale(for: now) - scale) < 0.01 else {
            throw ScrollDriverError.displayScaleChanged
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == selection.processID else {
            throw WindowFrameSourceError.captureFailed("The window moved to the background.")
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
        throw WindowFrameSourceError.captureFailed("The window moved to the background.")
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

    /// The text of an alert. Of the matcher's refusals only the size limit gets
    /// this far, in the alert for an image that could not be made; the others
    /// end in a retry or a save, and their English is for the log.
    private func localizedMessage(for error: Error) -> String {
        if let matchError = error as? FrameMatchError, matchError == .outputLimitExceeded {
            return LocaleManager.shared.string("The scrolling image reached the configured size limit.")
        }
        return error.localizedDescription
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
    ///
    /// With `preserveCrossAxis` — a viewport Accessibility found — the box keeps
    /// the margins across the scroll, so that what appears in them later is not
    /// cut off, but not what stays where it is and has something in it: that
    /// would be laid down once for every step.
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
        /// Whether a line across the scroll has anything in it — brightness that
        /// varies along the line, in either frame. A margin is blank; a picture
        /// or a panel of text that stays where it is is not.
        func lineHasContent(_ position: Int) -> Bool {
            let step = max(1, primaryLength / 700)
            for frame in [before, after] {
                var sum = 0.0, squares = 0.0, count = 0.0
                for along in stride(from: 0, to: primaryLength, by: step) {
                    let x = axis == .vertical ? position : along
                    let y = axis == .vertical ? along : position
                    let i = (y * frame.width + x) * 4
                    let value = Double(Int(frame.pixels[i]) + Int(frame.pixels[i + 1]) + Int(frame.pixels[i + 2])) / 765
                    sum += value; squares += value * value; count += 1
                }
                let mean = sum / count
                if max(0, squares / count - mean * mean).squareRoot() >= FrameMatcher.contentSpread { return true }
            }
            return false
        }

        let c0: Int, c1: Int
        if preserveCrossAxis {
            if let (activeStart, activeEnd) = cross {
                // What moved, and the empty lines around it — a web page's margins,
                // where something may yet appear. The first line with something
                // that stays where it is stops the widening: a picture in the
                // gallery above its strip, a panel of links beside the text.
                var low = activeStart
                while low > 0, !lineHasContent(low - 1) { low -= 1 }
                var high = activeEnd
                while high < crossLength, !lineHasContent(high) { high += 1 }
                c0 = low
                c1 = high
            } else {
                c0 = 0
                c1 = crossLength
            }
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

/// What a scrolling capture does when it fails before it has collected a frame.
nonisolated enum ScrollStartFailure: Equatable {
    /// An alert: the user has something to do about it, or nothing can be
    /// captured at all.
    case alert
    /// The window as it stands, by the ordinary path of the Window mode.
    case windowScreenshot

    /// Screen recording or Accessibility not granted, and the window closed:
    /// nothing a plain screenshot would not run into too, or no way to tell the
    /// user what to grant but to say so. Anything else — nothing scrolled, no
    /// scroll area, the scroll point covered, the window not brought forward, an
    /// event that would not send — is no reason to send the user away empty
    /// handed.
    static func response(to error: Error) -> ScrollStartFailure {
        switch error {
        case WindowFrameSourceError.permissionDenied,
             ScrollDriverError.accessibilityDenied,
             WindowFrameSourceError.windowUnavailable:
            return .alert
        default:
            return .windowScreenshot
        }
    }
}
