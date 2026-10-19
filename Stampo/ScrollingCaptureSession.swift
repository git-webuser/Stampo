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

    var onFinished: ((ScrollingCaptureResult) -> Void)?
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
    /// What Accessibility says the scroll area under the click is, for a
    /// direction; and whether the window — and, if one was found, that area —
    /// is where it should be at the click. Injected so that the choice of area
    /// per direction can be tested without a window server.
    private let resolveViewport: (@MainActor (WindowPickerSelection, ScrollAxis) throws -> ScrollViewportResolution)?
    private let checkTarget: @MainActor (_ container: AXUIElement?, _ axis: ScrollAxis) throws -> Void
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
    /// The lines of the forward step in flight, while there is one: what the
    /// pause cut short was to move the page by this many.
    private var inFlightLines: Int32?
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
    /// What the pairs of frames say about what the page pins to the viewport, as they come, for planning the next
    /// step: the assembler's own accumulator sees a pair only when it is laid.
    private var planningPinned = ScrollPinned.Accumulator()
    private var previous: CaptureFrame?
    private var zeroMotionCount = 0
    /// The lines of the steps decided as stationary since the last frame was
    /// kept. The page may have moved in them all the same, when the calibration
    /// they were judged by was wrong.
    private var stationaryLines: Int32 = 0
    /// What the next step is: ordinary, or a push through a section pinned to
    /// the viewport (`ScrollPush`).
    private var pushMode: ScrollPush.Mode = .none
    /// The last frame decided as stationary since a frame was kept, and the
    /// tiles that changed while the page stood: what a push is compared with.
    private var stationary: StationaryFrame?
    /// Whether every step decided as stationary since a frame was kept is one to
    /// rely on (`ScrollPush.isReliableStep`), and, once a push has begun after
    /// such steps, how many there were.
    private var stationaryAllReliable = true
    private var pushAfterReliableSteps = 0
    /// A push that changed the frame and was not placed, waiting for the step
    /// that says what the change was (`ScrollPush.afterCheck`): the frame kept
    /// before it, its own frame, and the lines it sent.
    private struct PushCheck {
        let before: CaptureFrame
        let frame: CaptureFrame
        let lines: Int32
    }
    private var pushCheck: PushCheck?
    /// Whether a push may be sent: not after a check has found the page going
    /// on under one, until a frame is laid.
    private var pushesAllowed = true
    /// Stretches of the page that no step could read, met by this capture, and
    /// the jerks that go on from the last of them (`ScrollUnreadableStretch`).
    private var unreadable = ScrollUnreadableStretch()
    /// The line of the last step that was placed firmly and that the calibration
    /// did not predict, kept to see whether the next such step agrees with it
    /// (`ScrollRecalibration`).
    private var rememberedLine: Double?
    /// The frames and steps of this capture on disk, when a Debug build is asked
    /// to keep them (`ScrollFrameDump`), and which attempt at a step is being made.
    private var dump: ScrollFrameDump?
    private var pendingAXTree: [String] = []
    /// Both probes use the same window, whose diagnostic tree needs only one
    /// walk in this session, including when the first walk runs out of time.
    private var didRecordAXTree = false
    private var stepNumber = 0
    /// Steps placed by the calibration alone, waiting for one the matcher places.
    private var temporary = TemporarySteps()
    private var repeatGuard = ScrollRepeatGuard()
    private var sidewaysSection = ScrollSidewaysSection()
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
    private var pixelsPerLine: Double? {
        didSet { galleryCalibration.reset() }
    }
    /// Whether a full step has matched what the calibration says, so that lines
    /// are known to move the page in proportion.
    private var linearityConfirmed = false {
        didSet { if !linearityConfirmed { galleryCalibration.reset() } }
    }
    /// A close full step that matched, short of the proof `linearityConfirmed`
    /// asks for. Whenever the calibration changes it has to be earned again.
    private var galleryCalibration = ScrollGalleryCalibration()
    /// The calibration is good enough to enter a sideways gallery with: the
    /// stricter `linearityConfirmed` still rules vertical laying and parallax.
    private var calibrationHeld: Bool { linearityConfirmed || galleryCalibration.held }
    /// Whether the queue that is waiting has had its short step (`ScrollQueueLaying.shortStepDue`).
    private var shortStepTried = false
    /// When the last wheel event was sent, and whether the capture waits after it for an overlay scroll bar to go
    /// (`ScrollOverlayScroller`).
    private var lastWheelAt = Date.distantPast
    private var overlayScrollerWait = false
    /// How long the last frame waited for the page to be still (`noteStillness`), as the line of a step says it.
    private var stillnessNote = ""
    /// When the capture began, for the length of it in the line `final`.
    private var startedAt: Date?
    /// Whether a full queue was laid by the calibration since the last step the matcher placed.
    private var queueLaidByCalibration = false

    init(selection: WindowPickerSelection, axis: ScrollAxis,
         excludeScrollbars: Bool = true,
         lengthLimit: Int = ScrollLengthLimit.default,
         shrinkToFit: Bool = false,
         activateSelectedWindow: (@MainActor (WindowPickerSelection) throws -> Void)? = nil,
         ownUICovers: @escaping @MainActor (CGPoint) -> Bool = { _ in false },
         ignoredWindows: @escaping @MainActor () -> Set<CGWindowID> = { [] },
         resolveViewport: (@MainActor (WindowPickerSelection, ScrollAxis) throws -> ScrollViewportResolution)? = nil,
         checkTarget: (@MainActor (AXUIElement?, ScrollAxis) throws -> Void)? = nil) {
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
        self.resolveViewport = resolveViewport
        self.checkTarget = checkTarget ?? { container, axis in
            if let container {
                try ScrollDriver.validateScrollTarget(selection: selection, point: selection.clickPoint,
                                                      container: container, axis: axis,
                                                      ignoring: ignoredWindows())
            } else {
                try ScrollDriver.validateSelectedWindow(selection: selection, point: selection.clickPoint,
                                                        ignoring: ignoredWindows())
            }
        }
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
        // The slice of the frame before the last waited for one more frame, which does not come.
        assembler.settlePending()
        if let repair = assembler.lastRepair {
            dump?.step("   settled: fixed \(repair.blocks) blocks: \(repair.fromNeighbour) from neighbour, \(repair.filled) filled, \(repair.kept) kept")
        }
        do {
            let image = try assembler.makeImage()
            dump?.save(image, as: "final")
            dump?.step("final \(image.width)x\(image.height)" + (startedAt.map {
                " · \(Int(max(0, Date().timeIntervalSince($0) - idleSeconds).rounded())) s"
            } ?? ""))
            // Before the buffers go: the assembler says whether the image was halved.
            let pixelsPerPoint = ScrollImageDensity.pixelsPerPoint(scale: scale, shrunk: assembler.isShrunk)
            releaseCaptureBuffers()
            onFinished?(ScrollingCaptureResult(image: image, pixelsPerPoint: pixelsPerPoint))
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
            pauseLedger.record(event, axis: axis, selectedAppIsFront: selectedAppIsFront)
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
            pauseLedger.record(event, axis: axis, selectedAppIsFront: selectedAppIsFront)
        }
    }

    // MARK: Pause and resume

    /// Whether the app whose page is captured is the one in front: a key goes to
    /// that one.
    private var selectedAppIsFront: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == selection.processID
    }

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
        pushMode = .none
        pushAfterReliableSteps = 0
        // A push waiting to be checked is not laid: the frame kept is the one
        // before it, and the pause finds the place from there.
        if let check = pushCheck {
            previous = check.before
            pushCheck = nil
        }
        rememberedLine = nil
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
            let pinned = pinnedTiles
            let finding = await Task.detached(priority: .userInitiated) {
                ScrollPlaceFinding.find(last: last, now: now, axis: axis, pinned: pinned)
            }.value
            try ensureActive()
            let action = ScrollResume.action(
                finding: finding, userMovement: userMovement, undone: undone,
                inFlightMovement: ScrollResume.inFlightMovement(lines: inFlightLines,
                                                                pixelsPerLine: pixelsPerLine, ledger: ledger))
            Log.capture.notice("scroll place after the pause · \(String(describing: finding), privacy: .public) → \(String(describing: action), privacy: .public)")
            dump?.step("place \(finding) → \(action)")
            switch action {
            case .goOn:
                stepInFlight = false
                inFlightLines = nil
                return true
            case .lay(let movement):
                let blocks = await pinnedBlocks(from: last, to: now, shift: movement)
                try ensureActive()
                guard try lay(now, movement: movement, pinned: blocks) != nil else {
                    finish()
                    return true
                }
                previous = now
                stepInFlight = false
                inFlightLines = nil
                zeroMotionCount = 0
                stationaryLines = 0
                stationary = nil
                stationaryAllReliable = true
                pushesAllowed = true
                consecutiveFailures = 0
                unmatchedScroll = 0
                return true
            case .layTemporary(let movement):
                // The step is taken to have arrived. It waits in the queue, as
                // a step placed by the calibration does, for one the matcher places.
                guard temporary.count < TemporarySteps.limit else { return false }
                let blocks = await pinnedBlocks(from: last, to: now, shift: nil)
                try ensureActive()
                guard acceptsFrame(now, head: "place after pause") else { return true }
                temporary.add(now, movement: movement, confirmed: false, pinned: blocks)
                repeatGuard.rememberCheckedFrame()
                noteProgress()
                previous = now
                stepInFlight = false
                inFlightLines = nil
                zeroMotionCount = 0
                stationaryLines = 0
                stationary = nil
                stationaryAllReliable = true
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
        inFlightLines = nil
        while remaining > 0 {
            try ensureActive()
            diagnosticStage = .validateTarget
            try validateCurrentScrollTarget(at: point)
            let lines = min(remaining, Int(ScrollResume.linesPerEvent))
            try sendWheel(axis: axis, lines: Int32(lines), backwards: !forward, at: point)
            remaining -= lines
            try await Task.sleep(for: .milliseconds(60))
        }
    }

    /// What `lay` put into the image besides the frame itself.
    private struct Laid {
        /// How many steps had waited.
        let waiting: Int
        /// The seam each of them fell at, in order.
        let queueSeams: [ScrollSeam.Choice]
        /// What laying them mended in the slices of the frames before (`ScrollPinned`).
        var repairs: [ScrollPinned.Repair] = []

        /// For the line of the step: nothing when no pinned element was in the way.
        var fixed: String {
            let blocks = repairs.reduce(0) { $0 + $1.blocks }
            guard blocks > 0 else { return "" }
            let copied = repairs.reduce(0) { $0 + $1.fromNeighbour }, filled = repairs.reduce(0) { $0 + $1.filled }
            let kept = repairs.reduce(0) { $0 + $1.kept }
            return " · fixed \(blocks) blocks: \(copied) from neighbour, \(filled) filled, \(kept) kept"
        }
    }

    /// The pinned blocks of a pair of frames, off the main thread, for a vertical scroll (`ScrollPinned`). Nil when
    /// there is no frame to compare with or the scroll goes the other way. `shift`: how far the page moved, when known.
    private func pinnedBlocks(from previous: CaptureFrame?, to frame: CaptureFrame, shift: Int?) async -> PinnedGrid? {
        guard axis == .vertical, let previous else { return nil }
        let grid = await Task.detached(priority: .userInitiated) {
            ScrollPinned.pinnedBlocks(previous: previous, current: frame, shift: shift)
        }.value
        if let grid { planningPinned.add(grid) }
        return grid
    }

    /// Lays a frame that is `movement` pixels along from the last frame into the
    /// image — first the steps that waited for one the matcher placed, at their
    /// own distances or, if the queue has been worked out again, at
    /// `queueMovements`. A gallery stage instead replaces the queue's last
    /// position. Nil when the image has no room for them.
    private func lay(_ frame: CaptureFrame, movement: Int, queueMovements: [Int]? = nil,
                     pinned: PinnedGrid? = nil, replacing previous: CaptureFrame? = nil,
                     head: String = "") throws -> Laid? {
        if let previous, (temporary.steps.last?.frame ?? assembler.lastFrame) != previous { return nil }
        guard acceptsFrame(frame, head: head) else { return nil }
        let waiting = temporary.take()
        var seams: [ScrollSeam.Choice] = []
        var repairs: [ScrollPinned.Repair] = []
        for (index, step) in waiting.enumerated() {
            let moved = queueMovements.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? step.movement
            guard makeRoom(for: moved) else {
                Log.capture.notice("scroll queue only partly laid · the image is full")
                return nil
            }
            try sidewaysSection.append(step.frame, movement: moved, to: &assembler, pinned: step.pinned)
            if let seam = assembler.lastSeam { seams.append(seam) }
            if let repair = assembler.lastRepair { repairs.append(repair) }
        }
        try ensureActive()
        if let previous {
            // Sideways motion leaves the stage at the last queued position;
            // adding its expected wheel distance would duplicate that position.
            guard try sidewaysSection.replaceLast(previous: previous, current: frame, in: &assembler)
            else { return nil }
        } else {
            guard makeRoom(for: movement) else { return nil }
            try sidewaysSection.append(frame, movement: movement, to: &assembler, pinned: pinned)
        }
        repeatGuard.rememberCheckedFrame()
        if let repair = assembler.lastRepair { repairs.append(repair) }
        noteProgress()
        return Laid(waiting: waiting.count, queueSeams: seams, repairs: repairs)
    }

    /// A repeated position ends the capture before it can enter the queue or
    /// the image. finish() discards the waiting queue before making the image.
    private func acceptsFrame(_ frame: CaptureFrame, head: String) -> Bool {
        guard !repeatGuard.checkForRepeat(frame, excluding: previous) else {
            recordStep("\(head) → saved: the page is going round")
            finish()
            return false
        }
        return true
    }

    /// The outcome of asking the tiles of a queue's frames which distances they
    /// bear out, after a step the matcher placed has shown that the calibration
    /// the queue was laid by is wrong.
    private struct QueueRelay {
        /// The new distances, in the queue's order — nil if the queue stays as
        /// it was laid.
        let movements: [Int]?
        let pixelsPerLine: Double
        /// For the line of the step in the log and in `steps.txt`.
        let note: String
    }

    /// A step that the matcher placed at a distance the calibration does not
    /// predict, with steps waiting that the calibration placed. Each waiting
    /// frame is looked at against the one before it, at the distance it was
    /// laid at and at the distance the placed step's line would give; whichever
    /// the tiles of more of them bear out is the queue's. A step that came
    /// after steps decided as stationary has two such distances — its own lines,
    /// or those and theirs, if the page moved in them too — and the tiles of its
    /// own pair of frames choose. Nil when there is nothing to ask: no frame to
    /// start from, or no step with lines.
    private func relayQueue(match: FrameMatch, lines: Int32, axisLength: Int,
                            searchLimit: Int) async throws -> QueueRelay? {
        guard let perLine = ScrollStepPlanner.pixelsPerLine(offset: match.offset, lines: Int(lines)),
              var before = assembler.lastFrame else { return nil }
        // A line that is nowhere near the calibration is more likely a step the
        // matcher misplaced than the page's own: 47 px for three lines against
        // 138 (2026-10-11-185309) broke the capture.
        if let current = pixelsPerLine, !ScrollRecalibration.isPlausible(newLine: perLine, current: current) {
            let refusal = ScrollRecalibration.refusal(newLine: perLine, current: current)
            Log.capture.notice("scroll \(refusal, privacy: .public)")
            return QueueRelay(movements: nil, pixelsPerLine: perLine, note: refusal)
        }
        let queue = temporary.steps
        guard let moved = ScrollQueueRelay.movements(lines: queue.map(\.lines), current: queue.map(\.movement),
                                                     pixelsPerLine: perLine, axisLength: axisLength)
        else { return nil }
        var jobs: [(index: Int, before: CaptureFrame, after: CaptureFrame, old: Int, one: Int, longer: Int?)] = []
        for (index, step) in queue.enumerated() {
            if step.lines != nil {
                let longer = ScrollQueueRelay.movementWithStationary(
                    lines: step.lines, stationaryLines: step.stationaryLines,
                    pixelsPerLine: perLine, axisLength: axisLength)
                jobs.append((index, before, step.frame, step.movement, moved[index], longer))
            }
            before = step.frame
        }
        guard !jobs.isEmpty else { return nil }
        let axis = self.axis
        let work = jobs
        let asked = await Task.detached(priority: .userInitiated) {
            var old = 0, new = 0, longerTaken = 0
            var chosen: [Int: Int] = [:]
            for job in work {
                old += FrameMatcher.evidence(previous: job.before, current: job.after, axis: axis,
                                             offset: job.old, searchLimit: searchLimit).consistent
                var distance = job.one
                var tiles = FrameMatcher.evidence(previous: job.before, current: job.after, axis: axis,
                                                  offset: job.one, searchLimit: searchLimit).consistent
                if let longer = job.longer {
                    let withStationary = FrameMatcher.evidence(previous: job.before, current: job.after, axis: axis,
                                                               offset: longer, searchLimit: searchLimit).consistent
                    if ScrollQueueRelay.prefersStationaryLines(tilesOne: tiles, tilesWithStationary: withStationary) {
                        distance = longer
                        tiles = withStationary
                        longerTaken += 1
                    }
                }
                new += tiles
                chosen[job.index] = distance
            }
            return (old: old, new: new, longerTaken: longerTaken, chosen: chosen)
        }.value
        try ensureActive()
        if ScrollQueueRelay.shouldRelay(tilesOld: asked.old, tilesNew: asked.new, newLine: perLine,
                                        currentLine: pixelsPerLine) {
            var distances = moved
            for (index, distance) in asked.chosen { distances[index] = distance }
            let over = asked.longerTaken == 0 ? "" : ", \(asked.longerTaken) over a stand"
            return QueueRelay(movements: distances, pixelsPerLine: perLine,
                              note: "queue re-laid at \(Int(perLine.rounded())) px/line (tiles \(asked.new) vs \(asked.old)\(over))")
        }
        return QueueRelay(movements: nil, pixelsPerLine: perLine,
                          note: "queue kept (tiles \(asked.old) vs \(asked.new))")
    }

    /// The capture has made headway: the seconds without it start again.
    private func noteProgress() {
        lastProgress = Date()
        idleAtProgress = idleSeconds
        recoveriesWithoutProgress = 0
    }

    /// The pointer is off the page or on the strip: hold the next step.
    private func pointerIsAway() -> Bool {
        let pointer = screenPointToCGPoint(NSEvent.mouseLocation, primaryHeight: cgPrimaryDisplayHeight())
        let window = ScrollDriver.currentWindowBounds(selection.windowID) ?? selection.bounds
        return ScrollInputGuard.shouldWait(pointer: pointer, window: window, overOwnUI: ownUICovers(pointer))
    }

    /// Holds still while the pointer is away. The time does not count towards the
    /// seconds without progress. There is no limit on the wait, on purpose: the
    /// pointer away is a hiccup like any other and is waited out, nothing
    /// collected is lost, and the strip with Save, pause and stop stays in view
    /// all along.
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
        pushCheck = nil
        temporary.discard()
        assembler.reset()
        sidewaysSection = ScrollSidewaysSection()
        repeatGuard = ScrollRepeatGuard()
        planningPinned = ScrollPinned.Accumulator()
    }

    /// A wheel event of the capture's own, with the time it was sent, for the wait that an overlay scroll bar asks.
    private func sendWheel(axis: ScrollAxis, lines: Int32, backwards: Bool = false, at point: CGPoint) throws {
        try ScrollDriver.sendScroll(axis: axis, lines: lines, backwards: backwards, at: point)
        lastWheelAt = Date()
    }

    /// Before the first look at a page after a wheel event: while an overlay scroll bar may still be shown, no
    /// sooner than `ScrollOverlayScroller.minimumDelay` after the event. The time counts in the wait for stillness.
    private func waitForOverlayScroller() async throws {
        guard overlayScrollerWait else { return }
        let remaining = ScrollOverlayScroller.remainingWait(sinceWheel: Date().timeIntervalSince(lastWheelAt))
        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
    }

    private func ensureActive() throws {
        guard !Task.isCancelled, !stopped else { throw CancellationError() }
    }

    func run() async {
        if startedAt == nil { startedAt = Date() }
        await guarded {
            try await self.prepare()
            try await self.stepLoop()
        }
    }

    /// One stretch of the capture, with what goes wrong in it dealt with: a
    /// cancellation ends it quietly; any other failure with nothing collected
    /// ends in an alert or the window's screenshot, and with something
    /// collected in a pause.
    ///
    /// Whatever a task that has been cancelled throws is the cancellation's
    /// doing and not a failure: a pause cancels the task, and the step in it
    /// may fail on its way out — and, run late after a resume, would pause the
    /// new task or end the capture in a screenshot.
    ///
    /// A hiccup that passes is the loop's next turn, not a call within this
    /// one: however many a capture waits out, they nest no deeper.
    func guarded(_ body: () async throws -> Void) async {
        var afterHiccup = false
        while true {
            do {
                if afterHiccup { try await continueFromHere() } else { try await body() }
                return
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled || stopped { return }
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
                        afterHiccup = true
                        continue
                    }
                }
                // Whatever it was — the window sent to the back, the scroll area
                // replaced, a hiccup that did not pass — the log has it; the
                // toast only says the capture stopped.
                pause(announce: true)
                return
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

    /// The scroll area for a direction, from Accessibility, checked to be where
    /// it should: set as the capture's viewport and container, and returned
    /// with the window's rounded edges inset. Where Accessibility finds none, or
    /// finds one that does not hold, it is the window, which the pixel probe
    /// narrows to what moves.
    func resolveArea(for axis: ScrollAxis) throws -> ScrollViewport {
        diagnosticStage = .resolveViewport
        var area: ScrollViewport
        let resolution = try resolveViewport?(selection, axis)
            ?? ScrollDriver.viewport(selection: selection, axis: axis, recordAXTree: !didRecordAXTree)
        switch resolution {
        case .accessibility(let resolved, let container):
            area = resolved
            scrollContainer = container
            diagnosticStage = .validateTarget
            do {
                try checkTarget(container, axis)
            } catch ScrollDriverError.scrollAreaUnavailable {
                // AX may expose a partial Chromium tree: keep the selected
                // CG window and let the pixel probe establish the viewport.
                Log.capture.notice("scroll capture viewport fallback: AX target identity was incomplete")
                area = ScrollDriver.windowFallbackViewport(for: selection)
                scrollContainer = nil
                try checkTarget(nil, axis)
            }
        case .window(let resolved, let axTree):
            // Chromium and other complex apps may provide a window capture
            // before exposing a complete AXWebArea chain. Pixel probing
            // will reduce this to the region that actually moves.
            area = resolved
            if !axTree.isEmpty, !didRecordAXTree {
                didRecordAXTree = true
                if let dump { dump.step(axTree.joined(separator: "\n")) }
                else { pendingAXTree = axTree }
            }
            scrollContainer = nil
            Log.capture.notice("scroll capture viewport fallback: AX hit did not resolve a suitable scroll container")
            diagnosticStage = .validateTarget
            try checkTarget(nil, axis)
        }
        guard let inset = area.insetWindowEdges(points: Geometry.roundedWindowEdgeInsetPoints) else {
            throw ScrollDriverError.scrollAreaUnavailable
        }
        viewport = inset
        return inset
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
        // The scroll area for the direction asked for. It is found again for
        // the other direction if the probe has to go that way: the area that
        // scrolls down and the one that scrolls sideways are not the same
        // (Finder's columns: a column, and the browser around them).
        var areaAxis = axis
        var baseViewport = try resolveArea(for: areaAxis)
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
        if !pendingAXTree.isEmpty {
            dump?.step(pendingAXTree.joined(separator: "\n"))
            pendingAXTree = []
        }
        dump?.save(before, as: "00-before")

        // From here the capture scrolls on its own, and a hand on the page
        // is the one thing that spoils it.
        startInputGuard()

        var settled: (axis: ScrollAxis, viewport: ScrollViewport, outcome: ProbeOutcome,
                      step: Int, lines: Int32, motionLimit: Int)?
        var settledStill = ""
        for candidate in Self.probeOrder(preferred: axis) {
            if candidate != areaAxis {
                // The frames are of the whole window, so a different area needs
                // no new look: the probe is read off the same ones.
                areaAxis = candidate
                baseViewport = try resolveArea(for: candidate)
            }
            let candidateViewport = try viewport(for: candidate, within: baseViewport)
            let initial = try cropped(before, to: candidateViewport)
            let probeStep = max(24, min(56, axisLength(of: initial, along: candidate) / 10))
            try ensureActive()
            let probePoint = currentScrollPoint()
            diagnosticStage = .probeMotion
            // Checked for the direction being probed: the area was chosen for
            // it, and the direction asked for has not settled yet.
            try validateCurrentScrollTarget(at: probePoint, axis: candidate)
            let probeLines = ScrollDriver.lineDelta(for: probeStep, backingScale: scale)
            try sendWheel(axis: candidate, lines: probeLines, at: probePoint)
            let after = try await ScrollCaptureCancellationBoundary.awaitActive {
                try await self.captureStableWindow(viewport: candidateViewport)
            }
            try ensureActive()
            try checkWindowAndFocus()
            let probeStill = stillnessNote
            if let outcome = Self.probeOutcome(before: before, after: after,
                                               viewportPixels: pixelRect(of: candidateViewport),
                                               axis: candidate,
                                               preserveCrossAxis: scrollContainer != nil,
                                               wholeWidth: candidateViewport.isWebPage && candidate == .vertical,
                                               crossLimit: crossLimit(of: candidateViewport, axis: candidate),
                                               extendToTrailingEdge: !candidateViewport.isWebPage) {
                dump?.save(after, as: "00-probe-window")
                let motionLimit = ScrollDriver.maximumLikelyMovement(
                    pixelStep: probeStep, backingScale: scale,
                    viewportLength: axisLength(of: initial, along: candidate))
                settled = (candidate, candidateViewport, outcome, probeStep, probeLines, motionLimit)
                settledStill = probeStill
                break
            }
            // Nothing moved that way. The next axis starts from what the
            // window shows now; when the probe moved nothing at all that is
            // the very frame taken before it.
            before = after
        }
        guard let settled else { throw ScrollDriverError.noMovingContent }
        let calibrated = try await startFromProbe(settled, stillNote: settledStill)
        if !calibrated { try await retryProbe(after: settled, lookingAt: before) }
    }

    /// What a probe settled on: the axis, its area, the pair of frames, and the step it was.
    private typealias SettledProbe = (axis: ScrollAxis, viewport: ScrollViewport, outcome: ProbeOutcome,
                                      step: Int, lines: Int32, motionLimit: Int)

    /// The capture begins from a pair of probe frames: the assembler with the first, and the probe matched against
    /// it, which calibrates the lines. True when it did. When the matcher refuses the pair, the capture is set up as
    /// it has always been after a refusal (the frame of the pair is the one the steps are compared with) and false
    /// comes back, for `retryProbe`.
    /// `matched`: a match already made, which a retry brings; nil makes it. `retry`: how the line of the step says it
    /// is a retry (nil for the first look); `frameSuffix`: the retry's mark on the frames it keeps; `final`: no
    /// attempt is left.
    private func startFromProbe(_ settled: SettledProbe, matched: Result<FrameMatch, Error>? = nil,
                                retry: String? = nil, frameSuffix: String = "", final: Bool = false,
                                stillNote: String = "") async throws -> Bool {
        axis = settled.axis
        assembler = ImageAssembler(axis: axis, maxLength: lengthLimit, scale: scale)
        planningPinned = ScrollPinned.Accumulator()
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
        sidewaysSection = ScrollSidewaysSection()
        repeatGuard = ScrollRepeatGuard()
        repeatGuard.remember(first)
        // The top of a site, as the window showed it, once above the first frame.
        var headerNote = ""
        if let header = settled.outcome.header, assembler.setHeader(header) {
            headerNote = " · header \(assembler.headerLength) px"
            dump?.save(header, as: "00-header\(frameSuffix)")
        }
        noteProgress()
        previous = probe
        dump?.step((retry == nil ? "area: " : "   area of the retry: ") + (settled.viewport.webPage.map {
            "web page (\($0.rawValue))" + (settled.axis == .vertical ? ", whole width" : ", the strip that moves")
        } ?? "not a web page") + headerNote
            + (settled.viewport.crossSpan.map { " · strip \(Int($0.upperBound - $0.lowerBound)) pt" } ?? "")
            + (overlayScrollerWait ? " · overlay scroller: not cut, waits ≥ \(ScrollOverlayScroller.minimumDelay) s" : ""))
        dump?.save(probe, as: "00-probe\(frameSuffix)")
        Log.capture.notice("scroll probe settled · \(self.axis == .vertical ? "vertical" : "horizontal", privacy: .public) · \(probeLines, privacy: .public) lines · limit \(probeMotionLimit, privacy: .public) px · scale \(self.scale, privacy: .public)")
        requestedStep = max(24, Int(Double(axisLength(of: first)) * 0.60))
        unmatchedScroll = 0
        pixelsPerLine = nil
        linearityConfirmed = false
        stationaryLines = 0
        stationary = nil
        stationaryAllReliable = true
        pushMode = .none
        pushAfterReliableSteps = 0
        pushCheck = nil
        pushesAllowed = true
        rememberedLine = nil
        let said = retry.map { "\($0) · " } ?? ""

        do {
            diagnosticStage = .match
            let match: FrameMatch
            if let matched {
                match = try matched.get()
            } else {
                match = try FrameMatcher.match(previous: first, current: probe, axis: axis,
                                               maximumOffset: probeMotionLimit + 24)
            }
            try ensureActive()
            let probeBlocks = await pinnedBlocks(from: first, to: probe, shift: match.offset)
            try ensureActive()
            try assembler.append(probe, movement: match.offset, pinned: probeBlocks)
            repeatGuard.remember(probe)
            notePinned(match.standing)
            queueLaidByCalibration = false
            shortStepTried = false
            consecutiveFailures = 0
            pixelsPerLine = ScrollStepPlanner.pixelsPerLine(offset: match.offset, lines: Int(probeLines))
            if let pixelsPerLine {
                let plan = ScrollStepPlanner.plan(target: requestedStep, pixelsPerLine: pixelsPerLine,
                                                  axisLength: axisLength(of: first), backingScale: scale)
                Log.capture.notice("scroll calibrated · \(Int(pixelsPerLine.rounded()), privacy: .public) px per line · \(plan.lines, privacy: .public) lines per step")
            }
            recordStep(0, "\(said)lines=\(probeLines) maximumOffset=\(probeMotionLimit + 24)\(stillNote) · match \(match.offset) px · confidence \(Self.percent(match.confidence)) · regions \(match.independentRegions)\(seamNote) → calibrated")
            return true
        } catch {
            recordStep(0, "\(said)lines=\(probeLines) maximumOffset=\(probeMotionLimit + 24)\(stillNote) · \(error) → probe not matched\(final ? ", going on without calibration" : "")")
            // The selected scroll view did not yield stable moving content
            // across the probe; keep the initial image for a partial save.
            previous = first
            unmatchedScroll = probeStep
            consecutiveFailures = 1
            return false
        }
    }

    /// The matcher refused the probe. A page can play an intro of its own, with nothing to scroll, as apple.com does for
    /// its products: the frame taken before the probe and the one after it are of different moments of it, and no
    /// steps compared with the first can ever match. The page goes back to where the probe began and the probe is
    /// taken again, about once a second, until it matches, for no longer than `ScrollProbeRetry.limit` from the
    /// first refusal; the capture then begins from the page as it is after the intro. Where it never matches the
    /// capture goes on as it always did after a refusal, from the last pair the probe moved something in.
    /// `firstLook`: the frame taken before the first probe, which the frame taken before each attempt, from the same
    /// place, is compared with: a page that did not change between two looks (`ScrollProbeRetry.keepsTrying`) is not
    /// playing an intro, and the attempts end.
    private func retryProbe(after first: SettledProbe, lookingAt firstLook: CaptureFrame) async throws {
        let began = Date()
        var lastLook = firstLook
        var attempts = 0
        // Per attempt: the pair when the probe moved something, and why the matcher refused it.
        var pairs: [SettledProbe?] = []
        var errors: [Error?] = []
        var stills: [String] = []
        attemptsLoop: while ScrollProbeRetry.beginsAttempt(after: Date().timeIntervalSince(began)) {
            try await Task.sleep(for: .seconds(ScrollProbeRetry.pause))
            try ensureActive()
            try checkWindowAndFocus()
            attempts += 1
            let label = "retry \(attempts) after \(String(format: "%.1f", Date().timeIntervalSince(began))) s"
            let point = currentScrollPoint()
            diagnosticStage = .validateTarget
            try validateCurrentScrollTarget(at: point, axis: first.axis)
            // Back to the lines of the probe, and a new look from there.
            try sendWheel(axis: first.axis, lines: first.lines, backwards: true, at: point)
            diagnosticStage = .capture
            let before = try await ScrollCaptureCancellationBoundary.awaitActive {
                try await self.captureStableWindow(viewport: first.viewport)
            }
            try ensureActive()
            try checkWindowAndFocus()
            dump?.save(before, as: "00-before-r\(attempts)")
            // Whether the page changed on its own since the last look from this place.
            let change = meanDifference(try cropped(lastLook, to: first.viewport), try cropped(before, to: first.viewport))
            lastLook = before
            let goesOn = ScrollProbeRetry.keepsTrying(changeSinceLastLook: change)
            diagnosticStage = .probeMotion
            try sendWheel(axis: first.axis, lines: first.lines, at: point)
            let after = try await ScrollCaptureCancellationBoundary.awaitActive {
                try await self.captureStableWindow(viewport: first.viewport)
            }
            try ensureActive()
            try checkWindowAndFocus()
            let stillNote = stillnessNote
            stills.append(stillNote)
            guard let outcome = Self.probeOutcome(before: before, after: after,
                                                  viewportPixels: pixelRect(of: first.viewport), axis: first.axis,
                                                  preserveCrossAxis: scrollContainer != nil,
                                                  wholeWidth: first.viewport.isWebPage && first.axis == .vertical,
                                                  crossLimit: crossLimit(of: first.viewport, axis: first.axis),
                                                  extendToTrailingEdge: !first.viewport.isWebPage) else {
                recordStep(0, "\(label) · lines=\(first.lines)\(stillNote) · nothing moved → not matched\(goesOn ? "" : " · page did not change, stop")")
                pairs.append(nil)
                errors.append(nil)
                if goesOn { continue }
                break attemptsLoop
            }
            dump?.save(after, as: "00-probe-window-r\(attempts)")
            let pair: SettledProbe = (first.axis, first.viewport, outcome, first.step, first.lines, first.motionLimit)
            diagnosticStage = .match
            let found: Result<FrameMatch, Error>
            do {
                found = .success(try FrameMatcher.match(previous: outcome.first, current: outcome.probe, axis: first.axis,
                                                        maximumOffset: first.motionLimit + 24))
            } catch {
                found = .failure(error)
            }
            switch found {
            case .success:
                _ = try await startFromProbe(pair, matched: found, retry: label, frameSuffix: "-r\(attempts)", stillNote: stillNote)
                Log.capture.notice("scroll probe matched after \(attempts, privacy: .public) retries · \(String(format: "%.1f", Date().timeIntervalSince(began)), privacy: .public) s")
                return
            case .failure(let error):
                recordStep(0, "\(label) · lines=\(first.lines) maximumOffset=\(first.motionLimit + 24)\(stillNote) · \(error) → not matched\(goesOn ? "" : " · page did not change, stop")")
                pairs.append(pair)
                errors.append(error)
                if !goesOn { break attemptsLoop }
            }
        }
        Log.capture.notice("scroll probe not matched in \(attempts, privacy: .public) retries · \(String(format: "%.1f", Date().timeIntervalSince(began)), privacy: .public) s")
        let ended = ScrollProbeRetry.beginsAttempt(after: Date().timeIntervalSince(began)) ? "page did not change" : "\(Int(ScrollProbeRetry.limit)) s over"
        if let index = ScrollProbeRetry.attemptToKeep(moved: pairs.map { $0 != nil }),
           let pair = pairs[index], let error = errors[index] {
            _ = try await startFromProbe(pair, matched: .failure(error), retry: "retry: \(ended)",
                                         frameSuffix: "-r\(index + 1)", final: true, stillNote: stills[index])
        } else {
            recordStep(0, "retry: \(ended) → probe not matched, going on without calibration")
        }
        noteProgress()
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
            let longStep = min(requestedStep, max(24, axisLength(of: oldFrame) * 3 / 4))
            // A push is one wheel event of twice the lines, with the search as
            // wide as a step is ever matched: where the page ends up when it has
            // gone past a section that pins it is not a multiple of the lines.
            // After a stretch that could not be read, steps are jerks, each one followed by a check, until one
            // of them is placed or the check shows the page going on.
            let isJerk = unreadable.isJerking
            let isCheck = unreadable.isChecking
            let isPush = ScrollPush.sendsPush(pushMode) || isJerk
            // Steps wait that the matcher could not place: one short step for the queue, which the frames may read
            // where they did not read the long ones.
            if temporary.isEmpty { shortStepTried = false }
            let short = !isPush && ScrollQueueLaying.shortStepDue(waiting: temporary.count,
                                                                  calibrationConfirmed: linearityConfirmed,
                                                                  tried: shortStepTried)
            let currentStep = short ? max(24, longStep / 2) : longStep
            if short {
                shortStepTried = true
                dump?.step("   short step: \(temporary.count) steps wait, half the step (\(longStep) → \(currentStep) px)")
            }
            // An element pinned at the bottom of the frame covers the page that is under it: that page has to come
            // up above it in the next frame, and it does if the step is no longer than where the element begins.
            // Only along a vertical scroll, and not for a push.
            let frameLength = axisLength(of: oldFrame)
            let ceiling = !isPush && axis == .vertical
                ? ScrollStepPlanner.ceiling(top: planningPinned.bottomAnchoredTop(rows: frameLength / ScrollPinned.block),
                                            axisLength: frameLength)
                : nil
            let plan = ScrollStepPlanner.plan(target: currentStep, pixelsPerLine: pixelsPerLine,
                                              axisLength: frameLength, backingScale: scale, ceiling: ceiling)
            if let ceiling, pixelsPerLine != nil {
                let free = ScrollStepPlanner.plan(target: currentStep, pixelsPerLine: pixelsPerLine,
                                                  axisLength: frameLength, backingScale: scale)
                if free.lines != plan.lines {
                    dump?.step("   step limited to \(ceiling) px by the element at the bottom: \(free.lines) → \(plan.lines) lines")
                }
            }
            let sentLines: Int32 = isPush ? plan.lines * 2 : plan.lines
            let motionLimit = isPush ? max(plan.motionLimit, axisLength(of: oldFrame) * 3 / 4) : plan.motionLimit
            let point = currentScrollPoint()
            try ensureActive()
            if dump != nil {
                dump?.step("   ax at point (step \(stepNumber + 1)): \(ScrollDriver.axChain(at: point, upTo: scrollContainer))")
            }
            diagnosticStage = .validateTarget
            try validateCurrentScrollTarget(at: point)
            stepInFlight = true
            inFlightLines = sentLines
            try sendWheel(axis: axis, lines: sentLines, at: point)
            diagnosticStage = .capture
            let next = try await ScrollCaptureCancellationBoundary.awaitActive {
                try await self.captureStableViewport(reference: oldFrame)
            }
            try ensureActive()
            try checkWindowAndFocus()
            stepNumber += 1
            let stillNote = stillnessNote
            dump?.save(next, as: String(format: "%02ld-step", stepNumber))

            /// Whether this is the first attempt at this step: an earlier
            /// failed one has moved the page by a distance nothing here
            /// accounts for.
            let cleanStep = unmatchedScroll == 0
            let maximumOffset = motionLimit + unmatchedScroll + 32
            let difference = meanDifference(oldFrame, next)
            let frameChanged = ScrollPush.isChanged(difference)
            let expected: Int? = cleanStep && !isPush
                ? pixelsPerLine.map { ScrollStepPlanner.predictedOffset(lines: Int(plan.lines), pixelsPerLine: $0) }
                : nil
            let head = "lines=\(sentLines)\(isPush ? " push" : "") motionLimit=\(motionLimit) maximumOffset=\(maximumOffset)"
                + " difference=\(String(format: "%.4f", difference))" + stillNote
            var refusedEvidence: FrameMatcher.StepEvidence?
            var secondLookNote = ""
            var secondLookConsistent = 0
            do {
                diagnosticStage = .match
                let axis = self.axis
                let match: FrameMatch
                do {
                    match = try await ScrollCaptureCancellationBoundary.awaitActive {
                        try await Task.detached(priority: .userInitiated) {
                            try FrameMatcher.match(previous: oldFrame, current: next, axis: axis,
                                                   maximumOffset: maximumOffset)
                        }.value
                    }
                } catch {
                    guard ScrollStepDecision.isUndecided(error) else { throw error }
                    let searchLimit = motionLimit + 32
                    let radius = Int((8 * scale).rounded())
                    let (raw, second) = try await ScrollCaptureCancellationBoundary.awaitActive {
                        await Task.detached(priority: .userInitiated) {
                            let raw = FrameMatcher.evidence(previous: oldFrame, current: next, axis: axis,
                                                            offset: expected, searchLimit: searchLimit)
                            let second = ScrollSecondLook.inspect(previous: oldFrame, current: next, axis: axis,
                                                                  maximumOffset: maximumOffset, searchLimit: searchLimit,
                                                                  expected: expected, radius: radius, raw: raw,
                                                                  frameChanged: frameChanged)
                            return (raw, second)
                        }.value
                    }
                    try ensureActive()
                    secondLookNote = second.note
                    guard let found = second.match else {
                        refusedEvidence = raw
                        secondLookConsistent = second.consistent
                        throw error
                    }
                    match = found
                }
                try ensureActive()
                if let check = pushCheck {
                    // The step after a push that changed the frame is placed:
                    // the page goes on as usual, and the push took it past
                    // content that no frame has. Nothing is laid or replaced;
                    // the page goes back to where the push began.
                    recordStep("\(head) · match \(match.offset) px · confidence \(Self.percent(match.confidence)) · regions \(match.independentRegions)\(secondLookNote) → check: page moves, push undone, back \(check.lines + sentLines) lines")
                    guard try await undoPush(check, checkLines: sentLines, at: point) else { return }
                    stepInFlight = false
                    inFlightLines = nil
                    continue
                }
                let jerkNumber = unreadable.jerks + 1
                if isCheck {
                    // The page moves in the check, from the frame of the jerk that was not placed: that frame is
                    // the page too, and the check is placed after it. Its distance says nothing of the lines.
                    let jerk = jerkFrameToLay(oldFrame)
                    let after = unreadable.afterCheck(placed: true, decision: nil, jerkRepeats: jerk == .repeatsPageLeft)
                    let line = "\(head) · match \(match.offset) px → unreadable stretch: jerk \(jerkNumber) not placed · check: moves"
                    if after == .nextJerk || after == .ceiling {
                        // The jerk's frame is a page already left: the check cannot be laid after it.
                        guard meetStandingCheck(next: next, line: "\(head) · match \(match.offset) px", jerkNumber: jerkNumber,
                                                ceiling: after == .ceiling, check: Self.repeatingJerkCheck) else { return }
                        if frameChanged { noteProgress() }
                        stepInFlight = false
                        inFlightLines = nil
                        continue
                    }
                    guard layJerkFrame(oldFrame, as: jerk) else { return }
                    recordStep(line + (jerk == .lay ? " → jerk frame laid edge to edge" : ", jerk frame is the page laid"))
                }
                guard try await layMatchedStep(next, from: oldFrame, match: match, lines: plan.lines,
                                               placement: isCheck ? .stretch : .matched(cleanStep: cleanStep),
                                               isPush: isPush, motionLimit: motionLimit,
                                               head: head, secondLookNote: secondLookNote) else { return }
                if isJerk {
                    unreadable.placed()
                    recordStep("· unreadable stretch: jerk \(jerkNumber) placed, ordinary steps go on")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                rememberedLine = nil
                if isJerk {
                    // A jerk is longer than the matcher looks. Whatever the frames say, it lays nothing and waits
                    // for nothing: an ordinary step from its frame says whether the page went on in it.
                    unreadable.jerkNotPlaced()
                    consecutiveFailures = 0
                    unmatchedScroll = 0
                    previous = next
                    // A frame that changed is headway, so that the checks do not run into the timeout.
                    if frameChanged { noteProgress() }
                    recordStep("\(head) · \(error) → unreadable stretch: jerk \(unreadable.jerks + 1) not placed, checking")
                    stepInFlight = false
                    inFlightLines = nil
                    continue
                }
                // The matcher cannot place the step. Why is a question for
                // the frames, asked once: which tiles stand still, and, when
                // the calibration says how far the page should have moved,
                // which tiles bear that out.
                let undecided = ScrollStepDecision.isUndecided(error)
                let expected = undecided ? expected : nil
                var evidence = refusedEvidence
                if undecided, evidence == nil {
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
                    unpinnedStanding: unpinned, queued: temporary.count,
                    frameUnchanged: !frameChanged, secondLookConsistent: secondLookConsistent))
                let said = (expected.map {
                    "expected \($0) px · \(evidence?.consistent ?? 0) tiles agree, \(evidence?.against ?? 0) against, \(required) needed"
                        + ((evidence?.near ?? 0) > 0 ? ", \(evidence?.near ?? 0) near" : "")
                        + ((evidence?.sticking ?? 0) > 0 ? ", \(evidence?.sticking ?? 0) sticking" : "")
                        + (evidence?.contradicted == true ? ", contradicted" : "")
                } ?? (!undecided ? "not to be predicted"
                      : isPush ? "a push, no distance expected"
                      : pixelsPerLine == nil ? "no calibration"
                      : "step not clean (\(unmatchedScroll) px unaccounted)")) + secondLookNote
                let consistent = evidence?.consistent ?? 0
                if isCheck {
                    // The check was not placed. The tiles say whether the page moved all the same, as after a push.
                    let jerkNumber = unreadable.jerks + 1
                    let line = "\(head) · \(error) · \(said)"
                    let moves = ScrollPush.movesPage(placed: false, decision: decision)
                    let jerk = moves ? jerkFrameToLay(oldFrame) : nil
                    let after = unreadable.afterCheck(placed: false, decision: decision, jerkRepeats: jerk == .repeatsPageLeft)
                    if let jerk, after == .jerkThenConfirmed {
                        guard layJerkFrame(oldFrame, as: jerk) else { return }
                        recordStep("\(line) → unreadable stretch: jerk \(jerkNumber) not placed · check: moves"
                                   + (jerk == .lay ? " → jerk frame laid edge to edge" : ", jerk frame is the page laid"))
                        // The tiles bear out its distance: it waits as a step that was confirmed, below.
                    } else {
                        guard meetStandingCheck(next: next, line: line, jerkNumber: jerkNumber, ceiling: after == .ceiling,
                                                check: jerk == .repeatsPageLeft ? Self.repeatingJerkCheck : "check: stands") else { return }
                        if frameChanged { noteProgress() }
                        stepInFlight = false
                        inFlightLines = nil
                        continue
                    }
                }
                // A check is no stage of a gallery: it goes on from the frame of a jerk.
                let galleryAllowed = !isCheck && (sidewaysSection.isActive
                    ? sidewaysSection.canContinue(axis: axis, verticalUndecided: undecided, isPush: isPush,
                                                   frameChanged: frameChanged, pushMode: pushMode,
                                                   checking: pushCheck != nil)
                    : ScrollSidewaysSection.canInspect(axis: axis, verticalUndecided: undecided, isPush: isPush,
                                                       expected: expected, calibrationConfirmed: calibrationHeld,
                                                       frameChanged: frameChanged, contradicted: evidence?.contradicted ?? false,
                                                       pushMode: pushMode, checking: pushCheck != nil))
                if galleryAllowed {
                    let before = temporary.steps.last?.frame ?? oldFrame
                    let section = sidewaysSection
                    let queued = temporary.steps.map(\.frame)
                    let stage = try await ScrollCaptureCancellationBoundary.awaitActive {
                        await Task.detached(priority: .userInitiated) {
                            section.inspect(previous: before, current: next, expected: expected,
                                            consistent: consistent, required: required, queued: queued)
                        }.value
                    }
                    try ensureActive()
                    if let stage, let handled = try await acceptSidewaysStage(
                        next, from: before, stage: stage, expected: expected, lines: sentLines,
                        motionLimit: motionLimit, consistent: consistent, required: required,
                        head: head, line: "\(head) · \(error) · \(said)") {
                        guard handled else { return }
                        stepInFlight = false
                        inFlightLines = nil
                        continue
                    }
                }
                // An empty queue keeps the existing stage recognition first.
                // Once it fails, supported down motion releases the latch before
                // the frame waits, so later stages cannot discard a real exit.
                sidewaysSection.releaseForVerticalSupport(consistent: consistent, required: required)
                if let check = pushCheck {
                    // Not placed. The tiles say whether it moves the page all
                    // the same; if they do not, the page stood and the section
                    // changed its stage.
                    let step = ScrollPush.afterCheck(mode: pushMode,
                                                     movesPage: ScrollPush.movesPage(placed: false, decision: decision))
                    if step.action == .undo {
                        recordStep("\(head) · \(error) · \(said) → check: page moves, push undone, back \(check.lines + sentLines) lines")
                        guard try await undoPush(check, checkLines: sentLines, at: point) else { return }
                    } else if !confirmSection(check, step: step, checkFrame: next,
                                               differenceFromPush: difference,
                                               line: "\(head) · \(error) · \(said)") {
                        return
                    }
                    stepInFlight = false
                    inFlightLines = nil
                    continue
                }
                let standing = "\(unpinned) unpinned middle tiles stand"
                // Only a step decided as stationary goes on in a push or a section.
                // A push is compared with the last frame that stood, the others
                // with the frame kept.
                let modeBefore = pushMode
                let standingFrame = stationary?.frame
                let changeDifference = ScrollPush.comparesWithStationaryFrame(mode: modeBefore,
                                                                              haveStationaryFrame: standingFrame != nil)
                    ? meanDifference(standingFrame ?? oldFrame, next) : difference
                var changed = ScrollPush.isChanged(changeDifference)
                // A push that changed the frame only where the frame changes by itself (a small animation) has
                // changed nothing: the end. Never the other way round, and only for a step decided as stationary:
                // any other would leave the way of `decision`.
                var ownMotionNote = ""
                if modeBefore == .push, decision == .stationary, let standingFrame, let ownMotion = stationary?.ownMotion {
                    let tiles = ScrollStillness.tileDifferences(standingFrame, next)
                    if changed, ScrollPush.changedBesidesOwnMotion(push: tiles, ownMotion: ownMotion) == false {
                        changed = false
                    }
                    if let tiles {
                        ownMotionNote = " · own motion \(ownMotion.count) tiles, "
                            + "\(ScrollPush.tilesChanged(outside: ownMotion, in: tiles)) others changed"
                    }
                }
                let afterBlank = pushAfterReliableSteps > 0
                let outcome = ScrollPush.outcome(decidedStationary: decision == .stationary, undecided: undecided,
                                                 changed: changed, mode: modeBefore)
                // A push that changed the frame is checked, tiles standing or not.
                let withoutTiles = ScrollPush.acceptsWithoutStandingTiles(
                    decidedStationary: decision == .stationary, undecided: undecided, changed: changed,
                    mode: modeBefore)
                let effective: ScrollStepDecision = withoutTiles ? .stationary : decision
                let push = ScrollPush.next(mode: modeBefore, outcome: outcome)
                var pushed = ScrollPush.sendsPush(modeBefore) && afterBlank ? " · after \(pushAfterReliableSteps) standing steps" : ""
                pushed += modeBefore == .push
                    ? " · \(standing) · vs \(standingFrame == nil ? "kept" : "standing") frame \(String(format: "%.4f", changeDifference))\(ownMotionNote)"
                    : " · \(standing)"
                pushMode = push.mode
                if push.mode == .none { pushAfterReliableSteps = 0 }
                switch effective {
                case .stationary where push.action == .end:
                    // A push moved nothing and changed nothing: the end of the content.
                    recordStep("\(head) · \(error) · \(said)\(pushed) → push: nothing changed, end")
                    Log.capture.notice("scroll push changed nothing · end")
                    finish()
                    return
                case .stationary where push.action == .check:
                    // The push changed the frame and nothing placed it. That is
                    // not yet a stage of a section: a page that the push took
                    // past more than a frame looks the same. An ordinary step
                    // from this frame says which.
                    recordStep("\(head) · \(error) · \(said)\(pushed) → push: frame changed, checking")
                    pushCheck = PushCheck(before: oldFrame, frame: next, lines: sentLines)
                    previous = next
                    unmatchedScroll = 0
                    consecutiveFailures = 0
                case .stationary where push.action == .hold:
                    stationary = StationaryFrame(frame: next)
                    consecutiveFailures = 0
                    recordStep("\(head) · \(error) · \(said)\(pushed) → push: nothing changed, an ordinary step next")
                case .stationary:
                    zeroMotionCount += 1
                    stationaryLines += sentLines
                    stationary = StationaryFrame.after(step: next, kept: oldFrame, previous: stationary)
                    stationaryAllReliable = stationaryAllReliable
                        && ScrollPush.isReliableStep(difference: difference, unpinnedStanding: unpinned)
                    consecutiveFailures = 0
                    recordStep("\(head) · \(error) · \(said) → stop: \(standing), page not moving \(zeroMotionCount) of 3")
                    if zeroMotionCount >= 3 {
                        // Steps wait that nothing placed, and the page seems to stand: a section that plays its own
                        // motion. That is no end of the content, and the third step would drop them.
                        if !temporary.isEmpty {
                            let stretch = try await meetUnreadableStretch(
                                next: next, trigger: .standing(count: zeroMotionCount, queued: temporary.count),
                                line: head)
                            if stretch == .ended { return }
                            if stretch == .laid { break }
                        }
                        // Three steps in a row proved without movement: the
                        // end of the content.
                        finish()
                        return
                    }
                    // Two in a row, and nothing waiting: the third is a push, in
                    // case the page snaps back to where it was after a short step.
                    if !sidewaysSection.isActive, ScrollPush.startsPush(zeroMotionCount: zeroMotionCount, queueIsEmpty: temporary.isEmpty,
                                             allowed: pushesAllowed) {
                        pushMode = .push
                        pushAfterReliableSteps = stationaryAllReliable ? zeroMotionCount : 0
                    }
                case .temporary(let confirmed):
                    // Not placed by the frames: placed where the calibration
                    // says, and kept apart until a step the matcher does
                    // place carries it into the image.
                    let blocks = await pinnedBlocks(from: oldFrame, to: next, shift: nil)
                    try ensureActive()
                    guard acceptsFrame(next, head: head) else { return }
                    temporary.add(next, movement: expected ?? 0, confirmed: confirmed, lines: sentLines,
                                  stationaryLines: stationaryLines, pinned: blocks, step: stepNumber)
                    repeatGuard.rememberCheckedFrame()
                    noteProgress()
                    recordStep("\(head) · \(error) · \(said) · \(standing) → temporary (\(confirmed ? "confirmed" : "unconfirmed")), queue \(temporary.count)")
                    previous = next
                    zeroMotionCount = 0
                    stationaryLines = 0
                    stationary = nil
                    stationaryAllReliable = true
                    unmatchedScroll = 0
                    requestedStep = max(24, Int(Double(axisLength(of: next)) * 0.60))
                    consecutiveFailures = 0
                case .finish:
                    // The queue is full and this step cannot be placed either. If the page moved in the queue, as
                    // the calibration, borne out by matched steps, says, the queue is laid by it and the capture goes
                    // on: a page that is whole to the end with seams that may be off is more than the page as far as
                    // it was read (`ScrollQueueLaying.shouldLay`).
                    var byCalibration = false
                    if axis == .vertical, let expected, let last = assembler.lastFrame {
                        let waiting = temporary.steps
                        let chain = [last] + waiting.map(\.frame) + [next]
                        let offsets = waiting.map(\.movement) + [expected]
                        let tiles = pinnedTiles
                        let costs = await Task.detached(priority: .userInitiated) {
                            (0..<offsets.count).map {
                                ScrollQueueLaying.pairCost(previous: chain[$0], current: chain[$0 + 1],
                                                           offset: offsets[$0], pinnedTiles: tiles)
                            }
                        }.value
                        try ensureActive()
                        byCalibration = ScrollQueueLaying.shouldLay(.init(
                            calibrationConfirmed: linearityConfirmed, queueConfirmed: waiting.map(\.confirmed),
                            currentConfirmed: (evidence?.consistent ?? 0) >= required,
                            contradicted: evidence?.contradicted ?? false, pairs: costs,
                            laidSinceMatch: queueLaidByCalibration))
                    }
                    guard byCalibration, let expected else {
                        // The calibration cannot lay them, and nothing reads them: a stretch that goes on in jerks
                        // is more than the capture that ends here.
                        let stretch = try await meetUnreadableStretch(
                            next: next, trigger: .queueFull(queued: temporary.count), line: "\(head) · \(error) · \(said)")
                        if stretch == .ended { return }
                        if stretch == .laid { break }
                        recordStep("\(head) · \(error) · \(said) → saved: \(temporary.count) steps wait for a confirmation")
                        finish()
                        return
                    }
                    let blocks = await pinnedBlocks(from: oldFrame, to: next, shift: nil)
                    try ensureActive()
                    guard let laid = try lay(next, movement: expected, pinned: blocks, head: head) else {
                        finish()
                        return
                    }
                    queueLaidByCalibration = true
                    recordStep("\(head) · \(error) · \(said) · \(standing) → queue laid by calibration: \(laid.waiting + 1) steps, none matched\(laid.fixed)")
                    Log.capture.notice("scroll queue laid by calibration · \(laid.waiting + 1, privacy: .public) steps, none matched")
                    previous = next
                    zeroMotionCount = 0
                    stationaryLines = 0
                    stationary = nil
                    stationaryAllReliable = true
                    unmatchedScroll = 0
                    requestedStep = max(24, Int(Double(axisLength(of: next)) * 0.60))
                    consecutiveFailures = 0
                case .retry:
                    consecutiveFailures += 1
                    guard consecutiveFailures <= 2 else {
                        if ScrollParallax.canInspect(axis: axis, calibrationConfirmed: linearityConfirmed,
                                                     cleanStep: cleanStep, isPush: isPush,
                                                     expected: expected, frameChanged: frameChanged), let expected {
                            let radius = Int((8 * scale).rounded())
                            let pair = try await ScrollCaptureCancellationBoundary.awaitActive {
                                await Task.detached(priority: .userInitiated) {
                                    ScrollQueueLaying.pairCost(
                                        previous: ScrollBackgroundFilter.highPass(oldFrame, radius: radius),
                                        current: ScrollBackgroundFilter.highPass(next, radius: radius),
                                        offset: expected, pinnedTiles: [])
                                }.value
                            }
                            try ensureActive()
                            if ScrollParallax.shouldLay(axis: axis, calibrationConfirmed: linearityConfirmed,
                                                        cleanStep: cleanStep, isPush: isPush, expected: expected,
                                                        frameChanged: frameChanged, pair: pair), let pair {
                                // This distance comes from the calibration, so it
                                // must not become independent evidence for it.
                                let inferred = FrameMatch(offset: expected, confidence: 0, independentRegions: 0)
                                guard try await layMatchedStep(next, from: oldFrame, match: inferred, lines: sentLines,
                                                               placement: .parallax, isPush: false, motionLimit: motionLimit,
                                                               head: head,
                                                               landingNote: "· parallax: laid by the calibration (shifted \(String(format: "%.2f", pair.shifted)), still \(String(format: "%.2f", pair.still)))") else { return }
                                break
                            }
                        }
                        // Steps wait that nothing placed, and the next will not match either: a section that
                        // plays its own motion, or a page that goes on in frames the matcher cannot read. What
                        // waits is another screen of the page, and the way on from it may read again.
                        if !temporary.isEmpty {
                            let stretch = try await meetUnreadableStretch(
                                next: next, trigger: .failed(queued: temporary.count),
                                line: "\(head) · \(error) · \(said)")
                            if stretch == .ended { return }
                            if stretch == .laid { break }
                        }
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
                    recordStep("\(head) · \(error) · \(said) · \(standing) → retry \(consecutiveFailures) of 2, back \(sentLines) lines")
                    requestedStep = max(12, currentStep / 2)
                    // Only this step's lines are undone: a probe that moved
                    // the page unmatched still has to be allowed for.
                    let back = try await returnPage(by: sentLines, at: point, reference: oldFrame)
                    let predicted = pixelsPerLine.map {
                        ScrollStepPlanner.predictedOffset(lines: Int(sentLines), pixelsPerLine: $0)
                    } ?? currentStep
                    switch try await landReturn(back, to: oldFrame, predicted: predicted) {
                    case .saved: return
                    case .ok: break
                    case .behind(let pixels):
                        let went = predicted - pixels
                        let axis = self.axis
                        let searchLimit = motionLimit + 32
                        let proof = await Task.detached(priority: .userInitiated) {
                            FrameMatcher.evidence(previous: oldFrame, current: next, axis: axis,
                                                  offset: went, searchLimit: searchLimit)
                        }.value
                        try ensureActive()
                        if ScrollReturn.canRecover(cleanStep: cleanStep, isPush: isPush, pixelsPerLine: pixelsPerLine,
                                                   went: went, evidence: proof, required: required) {
                            let recovered = FrameMatch(offset: went, confidence: 1, independentRegions: proof.consistent,
                                                       standing: proof.standing)
                            guard try await layMatchedStep(next, from: oldFrame, match: recovered, lines: sentLines,
                                                           placement: .recovered, isPush: false, motionLimit: motionLimit,
                                                           head: head,
                                                           landingNote: "· back landed \(pixels) px behind: the step went \(went) px · laid") else { return }
                            let forward = try await returnPage(by: sentLines, at: point, reference: next, backwards: false)
                            switch try await landReturn(forward, to: next, predicted: predicted) {
                            case .saved: return
                            case .behind(let remaining):
                                requestedStep += remaining
                                recordStep("· forward landed \(remaining) px behind: next step + \(remaining)")
                            case .ok: break
                            }
                            consecutiveFailures = 0
                        } else {
                            requestedStep = max(12, currentStep / 2) + pixels
                            recordStep("· back landed \(pixels) px behind: not confirmed, half step + \(pixels)")
                        }
                    }
                }
            }
            // The step is dealt with: a pause from here on cuts nothing short.
            stepInFlight = false
            inFlightLines = nil
        }
    }

    /// What the log says of a check that shows the page going on after a jerk whose frame is a page already left.
    private static let repeatingJerkCheck = "check: moves, but the jerk frame repeats a page already left → stands"

    private enum StretchOutcome {
        /// A series is laid, and the next steps are jerks.
        case laid
        /// Not a stretch: the capture ends as it would have.
        case declined
        /// The capture is over.
        case ended
    }

    /// The capture would end with steps waiting that nothing read. Frames of
    /// them — up to three, with the current one — are laid edge to edge, and
    /// the queue is dropped: what lies between them is lost, and a section
    /// longer than the queue may be shown more than once. The steps that
    /// follow are jerks, as through a pinned section (`ScrollPush`), until the
    /// matcher places one. `line` is what the step has said so far.
    private func meetUnreadableStretch(next: CaptureFrame, trigger: ScrollUnreadableStretch.Trigger,
                                       line: String) async throws -> StretchOutcome {
        guard let laid = assembler.lastFrame else {
            recordStep("\(line) → unreadable stretch declined: no frame laid")
            return .declined
        }
        let difference = meanDifference(laid, next)
        let situation = ScrollUnreadableStretch.Situation(
            trigger: trigger, isVertical: axis == .vertical, galleryActive: sidewaysSection.isActive,
            pushing: pushMode != .none || pushCheck != nil,
            framesChange: ScrollUnreadableStretch.isAnotherScreen(difference: difference),
            isRepeat: repeatGuard.checkForRepeat(next, excluding: previous))
        switch unreadable.decide(situation) {
        case .save:
            // The trigger fired and nothing is laid: the log says why, so that a capture that ends here can be read.
            let why = unreadable.refusal(situation)
            recordStep("\(line) → unreadable stretch declined: \(why?.note ?? "")"
                       + (why == .framesDoNotChange ? " (d=\(String(format: "%.4f", difference)))" : ""))
            return .declined
        case .tooMany:
            recordStep("\(line) → saved: the capture met too many stretches it could not read")
            Log.capture.notice("scroll too many unreadable stretches · saved what was collected")
            finish()
            return .ended
        case .series:
            break
        }
        let waiting = temporary.steps
        let frames = waiting.map(\.frame) + [next]
        let numbers = waiting.map(\.step) + [stepNumber]
        // What the frames show, off the main thread: which are whole screens (`ScrollSeries`).
        let analysis = try await ScrollCaptureCancellationBoundary.awaitActive {
            await Task.detached(priority: .userInitiated) {
                (frames.map(ScrollSeries.measure), ([laid] + frames).map(ScrollRepeatGuard.Signature.init))
            }.value
        }
        try ensureActive()
        let selection = ScrollSeries.choose(analysis.0) { a, b in analysis.1[a + 1].matches(analysis.1[b + 1]) }
        let chosen = selection.indices
        guard let last = chosen.last else {
            recordStep("\(line) → unreadable stretch declined: the frames show the page already laid")
            return .declined
        }
        for index in chosen {
            guard layEdgeToEdge(frames[index], line: line) else { return .ended }
        }
        // The queue's frames were remembered when they were queued; the current one is new.
        if last == frames.count - 1 { repeatGuard.rememberCheckedFrame() }
        let steps = frames.count
        temporary.discard()
        noteProgress()
        previous = frames[last]
        zeroMotionCount = 0
        stationaryLines = 0
        stationary = nil
        stationaryAllReliable = true
        pushMode = .none
        pushAfterReliableSteps = 0
        rememberedLine = nil
        unmatchedScroll = 0
        consecutiveFailures = 0
        requestedStep = max(24, Int(Double(axisLength(of: frames[last])) * 0.60))
        unreadable.begin()
        recordStep("\(line) → unreadable stretch: \(steps) steps, \(chosen.count) frames laid edge to edge · "
                   + Self.seriesNote(selection, numbers: numbers))
        Log.capture.notice("scroll unreadable stretch · \(steps, privacy: .public) steps, \(chosen.count, privacy: .public) frames laid edge to edge")
        return .laid
    }

    /// Which frames the series took and why, for the line of the stretch: `series: frames 27, 29, 31 of 26–34
    /// (flat: 32, 33, 34 dropped)`. Frames are named by the number of their step, or by their place in the
    /// queue (`#3`) when they have none.
    private static func seriesNote(_ selection: ScrollSeries.Selection, numbers: [Int]) -> String {
        func name(_ index: Int) -> String { numbers[index] > 0 ? "\(numbers[index])" : "#\(index)" }
        func list(_ indices: [Int]) -> String { indices.map(name).joined(separator: ", ") }
        var note = "series: frames \(list(selection.indices)) of \(name(0))–\(name(numbers.count - 1))"
        var why: [String] = []
        if !selection.fills.isEmpty { why.append("flat: \(list(selection.fills)) dropped") }
        if !selection.toppedUp.isEmpty { why.append("topped up: \(list(selection.toppedUp))") }
        if !selection.cut.isEmpty { why.append("cut: \(list(selection.cut)) behind whole ones") }
        if selection.byNumber { why.append("frames alike, by number") }
        if !why.isEmpty { note += " (" + why.joined(separator: "; ") + ")" }
        return note
    }

    /// A frame laid right after the last one, with no overlap. False when the
    /// capture is over: the image is full, or the frame could not be laid. The
    /// error stays here, in the log, and is not the step's.
    private func layEdgeToEdge(_ frame: CaptureFrame, line: String) -> Bool {
        guard makeRoom(for: axisLength(of: frame)) else {
            Log.capture.notice("scroll unreadable stretch only partly laid · the image is full")
            finish()
            return false
        }
        do {
            try assembler.appendEdgeToEdge(frame)
        } catch {
            recordStep("\(line) → unreadable stretch: frame not laid (\(error))")
            Log.capture.notice("scroll unreadable stretch frame not laid · saved what was collected")
            finish()
            return false
        }
        // A vertical placement, as any other: the gallery latch goes, and what follows is not a stage of it.
        sidewaysSection = ScrollSidewaysSection()
        return true
    }

    /// Whether a frame of the way after a stretch is to be laid: another screen
    /// than the last frame laid, and not one the capture has left. Asking
    /// remembers the frame for `rememberCheckedFrame`.
    private func laysEdgeToEdge(_ frame: CaptureFrame) -> Bool {
        guard let laid = assembler.lastFrame else { return false }
        return ScrollUnreadableStretch.laysFrame(
            anotherScreen: ScrollUnreadableStretch.isAnotherScreen(difference: meanDifference(laid, frame)),
            isRepeat: repeatGuard.checkForRepeat(frame, excluding: laid))
    }

    /// What the frame of a jerk that was not placed is to the image, asked when
    /// a check shows the page going on. Asking remembers the frame for
    /// `rememberCheckedFrame`.
    private func jerkFrameToLay(_ frame: CaptureFrame) -> ScrollUnreadableStretch.JerkFrame {
        guard let laid = assembler.lastFrame else { return .thePageLaid }
        return ScrollUnreadableStretch.jerkFrame(
            anotherScreen: ScrollUnreadableStretch.isAnotherScreen(difference: meanDifference(laid, frame)),
            isRepeat: repeatGuard.checkForRepeat(frame, excluding: laid))
    }

    /// The frame of a jerk, laid edge to edge when it is another screen. False
    /// when the capture is over.
    private func layJerkFrame(_ frame: CaptureFrame, as jerk: ScrollUnreadableStretch.JerkFrame) -> Bool {
        guard jerk == .lay else { return true }
        guard layEdgeToEdge(frame, line: "·") else { return false }
        repeatGuard.rememberCheckedFrame()
        noteProgress()
        return true
    }

    /// A check that shows the page standing: the jerk before it changed the
    /// section's stage and is not laid. The next jerk goes from this frame, not
    /// from the last frame laid, and the proof that the page stood is the tiles
    /// of the one pair, the jerk's frame and this. At the fourth, the way goes on
    /// as usual from this frame, laid edge to edge if it is another screen — the
    /// steps that follow are looked for from it, and the page is already far
    /// from where they would otherwise begin. `check` is what the log says of
    /// the check. False when the capture is over.
    private func meetStandingCheck(next: CaptureFrame, line: String, jerkNumber: Int, ceiling: Bool,
                                   check: String = "check: stands") -> Bool {
        previous = next
        unmatchedScroll = 0
        consecutiveFailures = 0
        guard ceiling else {
            recordStep("\(line) → unreadable stretch: jerk \(jerkNumber) not placed · \(check)")
            return true
        }
        let last = "jerk \(jerkNumber) of \(ScrollUnreadableStretch.jerkLimit) not placed · \(check)"
        guard laysEdgeToEdge(next) else {
            recordStep("\(line) → unreadable stretch: \(last), the page stands → saved")
            Log.capture.notice("scroll unreadable stretch · the page stood through the jerks · saved what was collected")
            finish()
            return false
        }
        guard layEdgeToEdge(next, line: line) else { return false }
        repeatGuard.rememberCheckedFrame()
        noteProgress()
        requestedStep = max(24, Int(Double(axisLength(of: next)) * 0.60))
        recordStep("\(line) → unreadable stretch: \(last) → last check laid edge to edge, ordinary steps go on")
        return true
    }

    /// A measured step, whether found directly or recovered from an overshot
    /// return, uses the same queue and seam bookkeeping. Only matched steps
    /// can change the calibration.
    private func layMatchedStep(_ next: CaptureFrame, from oldFrame: CaptureFrame, match: FrameMatch,
                                lines: Int32, placement: ScrollStepPlacement, isPush: Bool, motionLimit: Int,
                                head: String, secondLookNote: String = "",
                                landingNote: String = "") async throws -> Bool {
        // Steps wait that the calibration placed, and this one, which
        // the matcher placed, is not where the calibration says it
        // should be: the calibration may be the wrong one. The tiles of
        // the waiting frames say which distances they bear out.
        let cleanStep = placement.cleanStep
        var relay: QueueRelay?
        if cleanStep, let pixelsPerLine, !temporary.isEmpty, stationaryLines == 0,
           ScrollQueueRelay.isFirm(confidence: match.confidence),
           !ScrollStepPlanner.confirmsLinearity(offset: match.offset, lines: Int(lines),
                                                pixelsPerLine: pixelsPerLine) {
            relay = try await relayQueue(match: match, lines: lines,
                                         axisLength: axisLength(of: oldFrame), searchLimit: motionLimit + 32)
        }
        // The steps that waited for this one go into the image first.
        // The pinned blocks of the pair, off the main thread, before anything is taken from the queue.
        let replacement: CaptureFrame?
        if case .gallery = placement { replacement = oldFrame } else { replacement = nil }
        let blocks: PinnedGrid?
        if replacement == nil { blocks = await pinnedBlocks(from: oldFrame, to: next, shift: match.offset) }
        else { blocks = nil }
        try ensureActive()
        guard let laid = try lay(next, movement: match.offset, queueMovements: relay?.movements,
                                 pinned: blocks, replacing: replacement, head: head) else {
            finish()
            return false
        }
        notePinned(match.standing)
        queueLaidByCalibration = false
        galleryCalibration.matchedStep(offset: match.offset, lines: Int(lines), pixelsPerLine: pixelsPerLine,
                                       placement: placement, isPush: isPush)
        if let relay, relay.movements != nil {
            // The line is what this step shows. One step cannot confirm
            // that lines move the page in proportion; that waits for
            // the next full one.
            let was = Int((pixelsPerLine ?? 0).rounded()), now = Int(relay.pixelsPerLine.rounded())
            Log.capture.notice("scroll recalibrated · \(now, privacy: .public) px per line (was \(was, privacy: .public))")
            pixelsPerLine = relay.pixelsPerLine
            linearityConfirmed = false
        } else if !isPush, cleanStep, let pixelsPerLine,
           ScrollStepPlanner.confirmsLinearity(offset: match.offset, lines: Int(lines),
                                               pixelsPerLine: pixelsPerLine) {
            linearityConfirmed = true
        } else if !isPush, cleanStep, pixelsPerLine == nil,
                  let late = ScrollStepPlanner.pixelsPerLine(offset: match.offset,
                                                             lines: Int(lines)) {
            // The probe could not be matched — the first screen is
            // mostly a video, say — so the first step that does match
            // is what calibrates. Not one that follows a failed
            // attempt: that distance includes the attempt's.
            pixelsPerLine = late
            let latePlan = ScrollStepPlanner.plan(target: requestedStep, pixelsPerLine: late,
                                                  axisLength: axisLength(of: next), backingScale: scale)
            Log.capture.notice("scroll calibrated late · \(Int(late.rounded()), privacy: .public) px per line · \(latePlan.lines, privacy: .public) lines per step")
        }
        // No queue to say that the calibration is wrong: two firm steps in a
        // row that agree with each other and not with it say so.
        var recalibrated = ""
        if relay?.movements != nil {
            rememberedLine = nil
        } else if placement.updatesCalibration {
            let confirms = pixelsPerLine.map {
                ScrollStepPlanner.confirmsLinearity(offset: match.offset, lines: Int(lines), pixelsPerLine: $0)
            } ?? false
            let qualifies = !isPush && cleanStep && pixelsPerLine != nil && stationaryLines == 0
                && ScrollQueueRelay.isFirm(confidence: match.confidence)
            switch ScrollRecalibration.next(remembered: rememberedLine, offset: match.offset,
                                            lines: Int(lines), qualifies: qualifies,
                                            confirmsCalibration: confirms) {
            case .remember(let line):
                rememberedLine = line
            case .recalibrate(let line):
                let was = Int((pixelsPerLine ?? 0).rounded()), now = Int(line.rounded())
                rememberedLine = nil
                if let current = pixelsPerLine, !ScrollRecalibration.isPlausible(newLine: line, current: current) {
                    let refusal = ScrollRecalibration.refusal(newLine: line, current: current)
                    Log.capture.notice("scroll \(refusal, privacy: .public)")
                    recalibrated = " · \(refusal)"
                } else {
                    Log.capture.notice("scroll recalibrated · \(now, privacy: .public) px per line (was \(was, privacy: .public)) · two steps agree")
                    pixelsPerLine = line
                    linearityConfirmed = true
                    recalibrated = " · recalibrated \(now) px/line"
                }
            case .forget:
                rememberedLine = nil
            }
        }
        let queue = laid.waiting == 0 ? "" : " · "
            + (relay.map { "\($0.note) · " } ?? "")
            + "queue appended \(laid.waiting) (seams \(laid.queueSeams.map(\.summary).joined(separator: ", ")))"
        let pushed = isPush ? " · push: placed" : ""
        if replacement != nil {
            recordStep("\(landingNote)\(queue)\(laid.fixed)")
        } else {
            if !landingNote.isEmpty { recordStep(landingNote) }
            recordStep("\(head) · match \(match.offset) px · confidence \(Self.percent(match.confidence)) · regions \(match.independentRegions)\(match.near > 0 ? " · \(match.near) near" : "")\(match.sticking > 0 ? " · \(match.sticking) sticking" : "")\(secondLookNote)\(queue)\(seamNote)\(laid.fixed)\(recalibrated)\(pushed) → added")
        }
        pushMode = .none
        previous = next
        zeroMotionCount = 0
        stationaryLines = 0
        stationary = nil
        stationaryAllReliable = true
        pushesAllowed = true
        unmatchedScroll = 0
        requestedStep = max(24, Int(Double(axisLength(of: next)) * 0.60))
        consecutiveFailures = 0
        return true
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

    private func validateCurrentScrollTarget(at point: CGPoint, axis: ScrollAxis? = nil) throws {
        let axis = axis ?? self.axis
        guard !ownUICovers(point) else { throw ScrollDriver.selectedWindowNotFrontmost() }
        guard let container = scrollContainer else {
            try ScrollDriver.validateSelectedWindow(selection: selection, point: point,
                                                    ignoring: ignoredWindows())
            return
        }
        do {
            try ScrollDriver.validateScrollTarget(selection: selection, point: point, container: container,
                                                  axis: axis, ignoring: ignoredWindows())
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
    private func returnPage(by lines: Int32, at point: CGPoint, reference: CaptureFrame,
                            backwards: Bool = true) async throws -> CaptureFrame {
        // The step that failed is done with; what is in flight now is its undoing.
        inFlightLines = nil
        try ensureActive()
        diagnosticStage = .validateTarget
        try validateCurrentScrollTarget(at: point)
        try sendWheel(axis: axis, lines: lines, backwards: backwards, at: point)
        diagnosticStage = .capture
        // Settled before the next step is sent, so that the two do not run
        // into each other while the page still glides back.
        let back = try await ScrollCaptureCancellationBoundary.awaitActive {
            try await self.captureStableViewport(reference: reference)
        }
        try ensureActive()
        try checkWindowAndFocus()
        dump?.save(back, as: String(format: backwards ? "%02ld-back" : "%02ld-forward", stepNumber))
        return back
    }

    private enum LandReturnResult {
        case ok
        case behind(Int)
        case saved
    }

    /// Preserve content ahead of the frame kept, and report an overshoot behind
    /// it so the caller can plan from the actual landing rather than the target.
    private func landReturn(_ back: CaptureFrame, to target: CaptureFrame,
                            predicted: Int) async throws -> LandReturnResult {
        let difference = meanDifference(target, back)
        var forward: Int?, behind: Int?
        if ScrollPush.isChanged(difference) {
            let axis = self.axis
            let limit = axisLength(of: target) * 3 / 4 + 32
            let radius = Int((8 * scale).rounded())
            (forward, behind) = await Task.detached(priority: .userInitiated) {
                // Keep the established forward landing path and its priority.
                let forward = (try? FrameMatcher.match(previous: target, current: back, axis: axis,
                                                       maximumOffset: limit))?.offset
                let behind = forward.map { $0 > 0 } == true ? nil
                    : ScrollReturn.displacement(previous: back, current: target, axis: axis,
                                                maximumOffset: limit, radius: radius)
                return (forward, behind)
            }.value
            try ensureActive()
        }
        let pixels: Int
        switch ScrollReturn.landing(difference: difference, forward: forward, behind: behind, predicted: predicted) {
        case .same, .elsewhere: return .ok
        case .behind(let pixels): return .behind(pixels)
        case .further(let moved): pixels = moved
        }
        let blocks = await pinnedBlocks(from: target, to: back, shift: pixels)
        try ensureActive()
        guard let laid = try lay(back, movement: pixels, pinned: blocks, head: "· back landed \(pixels) px further") else {
            finish()
            return .saved
        }
        recordStep("· back landed \(pixels) px further, laid\(laid.fixed)")
        Log.capture.notice("scroll back landed \(pixels, privacy: .public) px further · laid")
        pushMode = .none
        pushAfterReliableSteps = 0
        previous = back
        zeroMotionCount = 0
        stationaryLines = 0
        stationary = nil
        stationaryAllReliable = true
        pushesAllowed = true
        unmatchedScroll = 0
        consecutiveFailures = 0
        requestedStep = max(24, Int(Double(axisLength(of: back)) * 0.60))
        return .ok
    }

    /// The first sideways match may find the way into the section still in
    /// the queue. Preserve that path once; subsequent stages replace its end.
    /// Nil leaves a frame that is not the last laid to the ordinary refusal path.
    private func acceptSidewaysStage(_ next: CaptureFrame, from oldFrame: CaptureFrame,
                                     stage: ScrollSidewaysSection.Stage, expected: Int?, lines: Int32,
                                     motionLimit: Int, consistent: Int, required: Int,
                                     head: String, line: String) async throws -> Bool? {
        guard let entry = sidewaysSection.entry(queueIsEmpty: temporary.isEmpty,
                                                calibrationConfirmed: calibrationHeld, expected: expected)
        else { return nil }
        if case .lay(let movement) = entry {
            let steps = temporary.count + 1
            let inferred = FrameMatch(offset: movement, confidence: 0, independentRegions: 0)
            guard try await layMatchedStep(next, from: oldFrame, match: inferred, lines: lines,
                                           placement: .gallery, isPush: false, motionLimit: motionLimit,
                                           head: head,
                                           landingNote: "\(line) · gallery: way in laid by the calibration (\(steps) steps) · \(stage.note)")
            else { return false }
            // This queue still has no matched vertical step behind it.
            queueLaidByCalibration = true
            return true
        }
        guard !temporary.isEmpty || assembler.lastFrame == oldFrame else { return nil }
        guard acceptsFrame(next, head: line) else { return false }
        var dropped = 0
        do {
            if temporary.isEmpty {
                guard try sidewaysSection.replaceLast(previous: oldFrame, current: next, in: &assembler)
                else { return nil }
            } else {
                guard let count = try sidewaysSection.replaceQueuedStage(previous: oldFrame, current: next,
                                                                         in: &assembler, queue: &temporary,
                                                                         consistent: consistent, required: required)
                else { return nil }
                dropped = count
            }
        } catch {
            recordStep("\(line) · gallery: \(stage.note) · frame not replaced")
            finish()
            return false
        }
        repeatGuard.rememberCheckedFrame()
        previous = next
        zeroMotionCount = 0
        stationaryLines = 0
        stationary = nil
        stationaryAllReliable = true
        unmatchedScroll = 0
        consecutiveFailures = 0
        noteProgress()
        recordStep("\(line) · gallery: \(stage.note) · frame replaced (\(sidewaysSection.stages))"
                   + (dropped > 0 ? " · queue of \(dropped) dropped" : ""))
        if sidewaysSection.isExhausted {
            recordStep("\(line) · saved: the sideways section did not end (\(ScrollSidewaysSection.limit) stages)")
            finish()
            return false
        }
        return true
    }

    /// The step after a push that changed the frame, and the page did not move:
    /// a pinned section changed its stage. The frame replaces the last one laid,
    /// the check's own if it changed after the push, and the pushes go on.
    /// Returns false when the capture is saved.
    private func confirmSection(_ check: PushCheck, step: ScrollPush.Step, checkFrame: CaptureFrame,
                                differenceFromPush: Double, line: String) -> Bool {
        let stage = ScrollPush.stageFrameIsChecks(differenceFromPush: differenceFromPush) ? checkFrame : check.frame
        do {
            try assembler.replaceLast(with: stage)
        } catch {
            recordStep("\(line) → check: section, frame not replaced")
            finish()
            return false
        }
        noteProgress()
        pushCheck = nil
        pushMode = step.mode
        previous = checkFrame
        zeroMotionCount = 0
        stationaryLines = 0
        stationary = nil
        stationaryAllReliable = true
        unmatchedScroll = 0
        consecutiveFailures = 0
        recordStep("\(line) → check: section · frame replaced (\(ScrollPush.pushes(in: step.mode)))")
        if ScrollPush.isExhausted(step.mode) {
            recordStep("saved: \(ScrollPush.limit) pushes and the page has not moved")
            finish()
            return false
        }
        return true
    }

    /// The page moves under the push: it went past content. The page goes back
    /// by the lines of the push and of the check, the frame kept is the one
    /// before the push, and no push is sent until a frame is laid.
    /// Returns false when the capture is saved.
    private func undoPush(_ check: PushCheck, checkLines: Int32, at point: CGPoint) async throws -> Bool {
        pushCheck = nil
        pushMode = .none
        pushAfterReliableSteps = 0
        pushesAllowed = false
        previous = check.before
        let back = try await returnPage(by: check.lines + checkLines, at: point, reference: check.before)
        let predicted = pixelsPerLine.map {
            ScrollStepPlanner.predictedOffset(lines: Int(check.lines + checkLines), pixelsPerLine: $0)
        } ?? requestedStep
        switch try await landReturn(back, to: check.before, predicted: predicted) {
        case .saved: return false
        case .ok: return true
        case .behind(let pixels):
            requestedStep += pixels
            recordStep("· back landed \(pixels) px behind: next step + \(pixels)")
            return true
        }
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

    /// What the last frame laid says about its seam, for the line of its step:
    /// nothing when the seam is in the middle of the overlap, as it nearly
    /// always is.
    private var seamNote: String {
        assembler.lastSeam?.note.map { " · \($0)" } ?? ""
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
            UserFacingError.present(.screenCaptureFailed(
                reason: LocaleManager.shared.string("Grant Screen Recording access to Stampo, then try again.")))
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
        overlayScrollerWait = false
        guard excludeScrollbars else { return base }
        let axScrollbarInset = ScrollDriver.scrollbarInsetPoints(container: scrollContainer,
                                                                  viewport: base.windowRect,
                                                                  axis: axis)
        switch ScrollOverlayScroller.decision(excludeScrollbars: excludeScrollbars, isWebPage: base.isWebPage,
                                              overlayStyle: NSScroller.preferredScrollerStyle == .overlay,
                                              axisScrollbarInset: axScrollbarInset,
                                              overMovingStrip: axScrollbarInset.map {
                                                  ScrollOverlayScroller.barLiesOver(strip: base.crossSpan,
                                                                                    area: base.windowRect,
                                                                                    axis: axis, inset: $0)
                                              } ?? true,
                                              fallbackPoints: Geometry.fallbackScrollbarInsetPoints) {
        case .leave:
            return base
        case .wait:
            // The bar is over the content and goes by itself: the edge is whole, and the frames wait for the bar.
            overlayScrollerWait = true
            Log.capture.notice("scrollbar edge not cut · overlay scroller over the content · frames wait \(ScrollOverlayScroller.minimumDelay, privacy: .public) s after a wheel event")
            return base
        case .cut(let reservedPoints):
            guard let adjusted = base.excludingScrollbar(axis: axis, insetPoints: reservedPoints) else {
                throw ScrollDriverError.scrollAreaUnavailable
            }
            let origin = axScrollbarInset == nil ? "fixed edge reserve" : "AX scrollbar geometry"
            Log.capture.notice("scrollbar edge excluded · \(reservedPoints, privacy: .public) points · \(origin, privacy: .public)")
            return adjusted
        }
    }

    /// Where the strip that moves lies across the scroll, in the pixels of the viewport's crop, when what moves is
    /// narrower than the area (`ScrollStrip`).
    private func crossLimit(of viewport: ScrollViewport, axis: ScrollAxis) -> ClosedRange<CGFloat>? {
        let rect = pixelRect(of: viewport)
        return ScrollStrip.pixelLimit(of: viewport.crossSpan,
                                      windowOrigin: axis == .vertical ? viewport.windowBounds.minX
                                                                      : viewport.windowBounds.minY,
                                      cropOrigin: axis == .vertical ? rect.minX : rect.minY, scale: scale)
    }

    /// The probe's second look, still the whole window. Settled is judged on
    /// the candidate viewport — the part that is going to be stitched — so a
    /// title bar or a fading scrollbar does not keep it waiting.
    private func captureStableWindow(viewport candidate: ScrollViewport) async throws -> CaptureFrame {
        let started = Date()
        try await waitForOverlayScroller()
        let waited = Date()   // The limit for stillness counts from here, after the wait for an overlay scroll bar.
        var latest = try await captureWindow()
        // Each frame is cropped once: the first on its first comparison, and
        // after that the crop that was made of it as the newer of a pair.
        var latestCrop: CaptureFrame?
        let deadline = waited.addingTimeInterval(ScrollStillness.limit)
        while Date() < deadline && !Task.isCancelled {
            try await Task.sleep(for: ScrollStillness.interval)
            let next = try await captureWindow()
            let before = try latestCrop ?? cropped(latest, to: candidate)
            let after = try cropped(next, to: candidate)
            let still = ScrollStillness.isStill(before, after)
            latest = next
            latestCrop = after
            if still {
                noteStillness(since: started, still: true)
                return latest
            }
        }
        noteStillness(since: started, still: false)
        return latest
    }

    private func captureStableViewport(reference: CaptureFrame) async throws -> CaptureFrame {
        let started = Date()
        try await waitForOverlayScroller()
        let waited = Date()   // The limit for stillness counts from here, after the wait for an overlay scroll bar.
        var latest = try await captureViewport()
        try ensureActive()
        let deadline = waited.addingTimeInterval(ScrollStillness.limit)
        while Date() < deadline && !Task.isCancelled {
            try await Task.sleep(for: ScrollStillness.interval)
            let next = try await captureViewport()
            try ensureActive()
            let still = ScrollStillness.isStill(latest, next)
            latest = next
            if still {
                noteStillness(since: started, still: true)
                return latest
            }
        }
        // Slow animations do not get to block a user indefinitely; the matcher
        // still has independent-region checks before it will append anything.
        noteStillness(since: started, still: false)
        return latest
    }

    /// How long the last frame waited for the page to be still, for the line of the step: "still 0.3 s", or
    /// "moving 1.8 s" when the limit came first.
    private func noteStillness(since started: Date, still: Bool) {
        stillnessNote = " · \(still ? "still" : "moving") \(String(format: "%.1f", Date().timeIntervalSince(started))) s"
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

    func waitForTargetFocus() async throws {
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
        // Out of the loop by a pause or a stop, not by the time: not a failure.
        try ensureActive()
        // Which of the two never came true: the app in front, or the point
        // free — and if not free, whose window is over it.
        let front = NSWorkspace.shared.frontmostApplication
        Log.capture.notice("scroll focus wait timed out · front \(front?.localizedName ?? "none", privacy: .public) pid \(front?.processIdentifier ?? 0, privacy: .public), want pid \(self.selection.processID, privacy: .public) window \(self.selection.windowID, privacy: .public) · at the point: \(ScrollDriver.describeWindow(at: self.selection.clickPoint, ignoring: self.ignoredWindows()), privacy: .public)")
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
        if case WindowFrameSourceError.windowUnavailable = error {
            return LocaleManager.shared.string("The selected window is no longer available.")
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
        /// The rows of the viewport above it, from the frame before the probe:
        /// what a site's window showed at the top, to lay once above the image.
        let header: CaptureFrame?
    }

    /// How tall the header of a web page is: the rows above the ones that
    /// scroll. A site scrolled down has one if the rows began to change below
    /// the top of its area; anything else — a strip that scrolls sideways, a
    /// gallery, a moving box that begins at the top — has none.
    nonisolated static func headerLength(wholeWidth: Bool, axis: ScrollAxis, movingStart: Int) -> Int? {
        guard wholeWidth, axis == .vertical, movingStart > 0 else { return nil }
        return movingStart
    }

    /// Cuts two whole-window frames to a direction's viewport and finds what
    /// moved between them. Nil when nothing did in that direction. Taking
    /// whole-window frames is what lets one starting frame serve either axis.
    nonisolated static func probeOutcome(before: CaptureFrame, after: CaptureFrame,
                                          viewportPixels: CGRect, axis: ScrollAxis,
                                          preserveCrossAxis: Bool, wholeWidth: Bool = false,
                                          crossLimit: ClosedRange<CGFloat>? = nil,
                                          extendToTrailingEdge: Bool = false) -> ProbeOutcome? {
        guard let initial = before.cropped(to: viewportPixels),
              let moved = after.cropped(to: viewportPixels),
              let found = movingContentRect(before: initial, after: moved, axis: axis,
                                            preserveCrossAxis: preserveCrossAxis,
                                            wholeWidth: wholeWidth,
                                            extendToTrailingEdge: extendToTrailingEdge,
                                            crossLimit: crossLimit),
              case let movingRect = found,
              let first = initial.cropped(to: movingRect),
              let probe = moved.cropped(to: movingRect)
        else { return nil }
        let header = headerLength(wholeWidth: wholeWidth, axis: axis, movingStart: Int(movingRect.minY)).flatMap {
            initial.cropped(to: CGRect(x: movingRect.minX, y: 0, width: movingRect.width, height: CGFloat($0)))
        }
        return ProbeOutcome(first: first, probe: probe, movingRect: movingRect, header: header)
    }

    /// How many lines in a row of something that stays still the widening of the
    /// moving box passes through, in pixels across the scroll.
    nonisolated static let shortStaticRun = 16

    /// How much a sample of a line may differ between the two frames of the
    /// probe — the sum of its three channels, out of 765 — for the line to be
    /// said not to have changed. A picture that does not move is identical; the
    /// edge of a pale band that has moved is not.
    nonisolated static let stillTolerance = 15

    /// Finds the 2D bounding box of pixels that changed between the probe pair.
    /// This works for an AX-resolved viewport and for a whole-window fallback,
    /// where fixed sidebars/headers must be excluded before stitching.
    ///
    /// With `preserveCrossAxis` — a viewport Accessibility found — the box keeps
    /// the margins across the scroll, so that what appears in them later is not
    /// cut off, but not what stays where it is and has something in it: that
    /// would be laid down once for every step.
    ///
    /// With `wholeWidth` — the area is a web page, scrolled down — the box is the
    /// whole width of the viewport across the scroll, whatever stands still in
    /// it: a site is made to be scrolled in the width of the browser's window,
    /// and a side panel, a floating card or a pinned bar of its own is part of
    /// what the reader sees, and so is the bottom of the window, down to the
    /// edge of the area; the top is where the rows began to change, below the
    /// pinned bar. It is about a page that is read downwards: a strip that
    /// scrolls sideways inside a page is the strip, and `wholeWidth` does
    /// nothing for it. Without it, what stands still above and
    /// below the moving rows does not narrow the box: only the lines that go into
    /// the frames are looked at.
    ///
    /// With `extendToTrailingEdge` — an area that is not a page — the box runs on to the edge the content comes
    /// from (the right edge of a capture sideways, the bottom of one down) over the lines across the scroll that
    /// hold nothing, or something that changed between the frames; it stops where a run of more than
    /// `shortStaticRun` lines that hold something standing still begins. Where the probe ends, the content that
    /// is still to arrive can be an almost empty strip (the last column of Finder, with one line in it), too faint
    /// to count as moving, and a box that ended there would cut the column off when it came in. The leading edge
    /// stays where the probe found it. `crossLimit` (`ScrollStrip`) narrows the box across the scroll before the
    /// lines of the edge are looked at: what lies outside it is not in the frames.
    nonisolated static func movingContentRect(before: CaptureFrame, after: CaptureFrame,
                                               axis: ScrollAxis, preserveCrossAxis: Bool = false,
                                               wholeWidth: Bool = false,
                                               extendToTrailingEdge: Bool = false,
                                               crossLimit: ClosedRange<CGFloat>? = nil) -> CGRect? {
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
        guard let (p0, movingEnd) = primary, movingEnd - p0 >= primaryLength / 3 else { return nil }
        // A site scrolled down shows the bottom of the browser's window in every
        // frame: where the rows stopped changing at the probe — an empty
        // background under the content — is not where the page ends.
        let p1 = wholeWidth && axis == .vertical ? primaryLength : movingEnd
        /// Whether a line (the samples `pixel` gives, at every `step` of `range`) holds
        /// something that stays where it is:
        /// it has something in it — brightness that varies along the line, in
        /// either frame — and not one sample of it changed between the frames, to
        /// within `stillTolerance`. A margin is blank; a picture or a panel of
        /// text that does not move is the same pixel for pixel; but a margin that
        /// crosses a pale band running the width of the page — a menu, a banner,
        /// the grey background of a section — has something in it, and is not
        /// still: the band's edge moved with the page.
        func stillContent(_ range: Range<Int>, step: Int, pixel: (Int) -> Int) -> Bool {
            var hasContent = false
            var sums = (0.0, 0.0), squares = (0.0, 0.0), count = 0.0
            for along in stride(from: range.lowerBound, to: range.upperBound, by: step) {
                let i = pixel(along) * 4
                let was = Int(before.pixels[i]) + Int(before.pixels[i + 1]) + Int(before.pixels[i + 2])
                let now = Int(after.pixels[i]) + Int(after.pixels[i + 1]) + Int(after.pixels[i + 2])
                // One sample that changed is enough: not still.
                if abs(was - now) > Self.stillTolerance { return false }
                let a = Double(was) / 765, b = Double(now) / 765
                sums.0 += a; sums.1 += b
                squares.0 += a * a; squares.1 += b * b
                count += 1
            }
            guard count > 0 else { return false }
            for (sum, square) in [(sums.0, squares.0), (sums.1, squares.1)] {
                let mean = sum / count
                if max(0, square / count - mean * mean).squareRoot() >= FrameMatcher.contentSpread {
                    hasContent = true
                }
            }
            return hasContent
        }
        /// The line at `position` across the scroll's cross axis, along the rows that move.
        func lineIsStillContent(_ position: Int) -> Bool {
            stillContent(p0..<p1, step: max(1, primaryLength / 700)) { along in
                let x = axis == .vertical ? position : along
                let y = axis == .vertical ? along : position
                return y * before.width + x
            }
        }

        var c0: Int, c1: Int
        if wholeWidth, axis == .vertical {
            c0 = 0
            c1 = crossLength
        } else if preserveCrossAxis {
            if let (activeStart, activeEnd) = cross {
                // What moved, and the lines around it that are empty — a web
                // page's margins, where something may yet appear — or in which
                // something moved, or that hold something that stays still for
                // no more than a few pixels: the
                // faint edges of the moving text itself, a rule, a border. A run
                // of such lines longer than that is a picture above the strip in
                // a gallery, a panel of links beside the text, and the widening
                // stops where it begins.
                var low = activeStart, run = 0, position = activeStart - 1
                while position >= 0 {
                    if lineIsStillContent(position) {
                        run += 1
                        if run > ScrollingCaptureSession.shortStaticRun { break }
                    } else {
                        run = 0
                        low = position
                    }
                    position -= 1
                }
                var high = activeEnd
                run = 0
                position = activeEnd
                while position < crossLength {
                    if lineIsStillContent(position) {
                        run += 1
                        if run > ScrollingCaptureSession.shortStaticRun { break }
                    } else {
                        run = 0
                        high = position + 1
                    }
                    position += 1
                }
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
        if let crossLimit {
            let across = axis == .vertical
                ? CGRect(x: c0, y: 0, width: c1 - c0, height: 1) : CGRect(x: 0, y: c0, width: 1, height: c1 - c0)
            let limited = ScrollStrip.narrowed(across, axis: axis, to: crossLimit)
            (c0, c1) = axis == .vertical ? (Int(limited.minX), Int(limited.maxX)) : (Int(limited.minY), Int(limited.maxY))
        }
        // The box ends where the probe's moving rows ended, or, with `extendToTrailingEdge`, where a run of lines
        // across the scroll that hold something standing still begins, or at the edge of the area. A line is looked at
        // over the cross range of the box: a margin of the window beyond it is not what the frames take. Only a run
        // longer than `shortStaticRun` stops it, as in the widening above: the lines of a band that is wider than the
        // step (the selected row of a column) are the same in both frames wherever the band is, and between the
        // letters of its text.
        var end = p1
        if extendToTrailingEdge, p1 < primaryLength {
            end = primaryLength
            let step = max(1, crossLength / 700)
            var run = 0
            for position in p1..<primaryLength {
                let holdsStillContent = stillContent(c0..<c1, step: step) { across in
                    let x = axis == .vertical ? across : position
                    let y = axis == .vertical ? position : across
                    return y * before.width + x
                }
                run = holdsStillContent ? run + 1 : 0
                if run > ScrollingCaptureSession.shortStaticRun {
                    end = position - run + 1
                    break
                }
            }
        }
        return axis == .vertical
            ? CGRect(x: c0, y: p0, width: c1 - c0, height: end - p0)
            : CGRect(x: p0, y: c0, width: end - p0, height: c1 - c0)
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
