import AppKit
import SwiftUI

// MARK: - Panel timing constants

/// Animation durations and dispatch delays used throughout NotchPanelController.
/// Centralised here so every phase of the open/close/morph choreography is
/// documented and easy to tune without hunting for magic numbers.
enum PanelTiming {
    /// Content fade-out before a tray→main morph (easeIn).
    static let hideAnimation:       TimeInterval = 0.18
    /// Countdown / tray-content crossfade (easeOut).
    static let crossfade:           TimeInterval = 0.16
    /// One-frame settle: lets SwiftUI process a visibility change before
    /// starting the shape morph that follows it.
    static let oneFrameSettle:      TimeInterval = 0.03
    /// Full tray-close morph (shape + position, cubic easing).
    static let trayCloseMorph:      TimeInterval = 0.28
    /// Delay between showAnimated() and switchToTray() so the open
    /// animation has a head-start before tray content appears.
    static let showBeforeTray:      TimeInterval = 0.25
}

// MARK: - Interaction state

@Observable final class NotchPanelInteractionState {
    var isEnabled: Bool = true
    var contentVisibility: Double = 1.0
}

// MARK: - Root state

enum NotchPanelRoute {
    case main
    case tray
    case cdwn
}

@Observable final class NotchPanelRootState {
    var route: NotchPanelRoute = .main
    var metrics: NotchMetrics = .fallback()
    /// 0.0 = Main, 1.0 = Tray
    var progress: CGFloat = 0.0
    /// Pre-faded to 0.0 before tray→main morph starts; reset to 1.0 after close completes
    var trayContentVisible: CGFloat = 1.0
    /// 0.0 = Main visible, 1.0 = Countdown visible (crossfade, no morph)
    var countdownVisible: CGFloat = 0.0
    var countdownSeconds: Int = 0
    var countdownTotal: Int = 0
    var isTrayPinned: Bool = false
}

private struct NotchPanelRootView: View {
    var rootState: NotchPanelRootState
    var interaction: NotchPanelInteractionState
    var model: NotchPanelModel
    var trayModel: NotchTrayModel

    let onClose: () -> Void
    let onCapture: (CaptureMode, CaptureDelay) -> Void
    let onToggleTray: () -> Void
    let onPickColor: () -> Void
    let onModeDelayChanged: () -> Void
    let onBack: () -> Void
    let onTogglePin: () -> Void
    let onStopCountdown: () -> Void
    let onCaptureNow: () -> Void

    private var m: NotchMetrics { rootState.metrics }
    private var trayScrollHeight: CGFloat { 55 }
    private var trayH: CGFloat { m.panelHeight + trayScrollHeight }
    private var p: CGFloat { rootState.progress }

    var body: some View {
        ZStack(alignment: .top) {
            // Single morphing background shape
            PanelMorphShape(progress: p, pixel: m.pixel)
                .fill(Color.black)
                .compositingGroup()
                .frame(height: trayH)

            // Main — visible only in the last ~60% of the morph; hidden during countdown
            NotchPanelView(
                metrics: m,
                interaction: interaction,
                model: model,
                isTrayOpen: rootState.route == .tray,
                onClose: onClose,
                onCapture: onCapture,
                onToggleTray: onToggleTray,
                onPickColor: onPickColor,
                onModeDelayChanged: onModeDelayChanged
            )
            .opacity(max(0.0, min(1.0, (0.6 - p) / 0.6)) * (1.0 - rootState.countdownVisible))
            .animation(.easeOut(duration: PanelTiming.crossfade), value: rootState.countdownVisible)
            .allowsHitTesting(p < 0.5 && rootState.countdownVisible < 0.5)

            // Countdown — crossfades over Main without resizing the panel
            CountdownView(
                metrics: m,
                interaction: interaction,
                secondsRemaining: rootState.countdownSeconds,
                totalSeconds: rootState.countdownTotal,
                onStop: onStopCountdown,
                onCaptureNow: onCaptureNow
            )
            .opacity(rootState.countdownVisible)
            .animation(.easeOut(duration: PanelTiming.crossfade), value: rootState.countdownVisible)
            .allowsHitTesting(rootState.countdownVisible >= 0.5)
            .frame(height: m.panelHeight)

            // Tray — appears as p→1; content is pre-faded via trayContentVisible.
            // Two separate opacity modifiers: SwiftUI tracks them independently so
            // the progress animation does not "drag" trayContentVisible along with it.
            NotchTrayView(
                metrics: m,
                trayModel: trayModel,
                isPinned: rootState.isTrayPinned,
                onBack: onBack,
                onTogglePin: onTogglePin
            )
            .opacity(rootState.trayContentVisible)
            .opacity(p)
            .allowsHitTesting(p >= 0.5)
        }
        .frame(height: trayH)
        .allowsHitTesting(interaction.isEnabled)
    }
}

// MARK: - Panel controller

final class NotchPanelController: NSObject {
    // MARK: Private (main-file only)
    private var panel: NSPanel?
    private let interactionState = NotchPanelInteractionState()
    private var isMenuTracking: Bool = false
    private var trayTransitionInFlight: Bool = false
    private(set) var isExpanded: Bool = false
    private var escEventTap: CFMachPort?
    private var escEventTapSource: CFRunLoopSource?
    private var notificationObservers: [NSObjectProtocol] = []

    // MARK: Internal (accessible from extension files)
    var currentScreen: NSScreen?
    let rootState = NotchPanelRootState()
    let model = NotchPanelModel()
    let trayModel = NotchTrayModel()
    let screenshot = ScreenshotService()
    let colorPicker = ColorPickingCoordinator()

    enum CaptureTarget {
        case screen
        case rect(CGRect)
        case windowID(CGWindowID)
    }

    var countdownTimer: Timer?
    var countdownCaptureTarget: CaptureTarget = .screen
    var countdownScreen: NSScreen?

    let selectionOverlay = SelectionOverlay()
    let windowPickerOverlay = WindowPickerOverlay()
    var preSelectionInFlight: Bool = false

    var metrics = NotchMetrics.fallback() {
        didSet { rootState.metrics = metrics }
    }

    var route: NotchPanelRoute {
        get { rootState.route }
        set { rootState.route = newValue }
    }

    // MARK: - Init

    override init() {
        super.init()
        colorPicker.hidePanel = { [weak self] completion in self?.hideAnimated(completion: completion) }
        colorPicker.addColor  = { [weak self] color in self?.trayModel.add(color: color) }
        colorPicker.resetRoute = { [weak self] in
            self?.route = .main
            self?.rootState.progress = 0.0
        }
        colorPicker.hideCursorBeforeHide = { CursorOverlay.hideCursorAfterMenuCloses() }
        screenshot.onCaptured = { [weak self] url in
            self?.trayModel.add(screenshotURL: url)
        }
        screenshot.onThumbnailTapped = { [weak self] in
            guard let self else { return }
            if self.isVisible {
                self.switchToTray()
            } else {
                guard let screen = self.currentScreen ?? NSScreen.main else { return }
                self.showAnimated(on: screen)
                // Slight delay so show animation starts before tray transition
                DispatchQueue.main.asyncAfter(deadline: .now() + PanelTiming.showBeforeTray) {
                    self.switchToTray()
                }
            }
        }
        screenshot.onDelete = { [weak self] url in
            self?.trayModel.remove(screenshotURL: url)
        }
        let t1 = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isMenuTracking = true
        }
        let t2 = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isMenuTracking = false
        }
        // Space switched — keep the panel on top when it is already visible.
        // canJoinAllSpaces keeps it present on all spaces; orderFrontRegardless
        // ensures it stays above the new space's windows without rebinding.
        let t3 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            panel.orderFrontRegardless()
        }
        notificationObservers = [t1, t2, t3]
    }

    deinit {
        // Some observers are registered on NSWorkspace.notificationCenter,
        // others on NotificationCenter.default — remove from both.
        notificationObservers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        notificationObservers.removeAll()
        removeEscMonitor()
        // Ensure the scheduled Timer can't fire into a deallocated controller.
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    /// Shows the panel on the current active Space, then extends it to all spaces.
    /// Order matters: macOS binds the window to a Space at the moment of orderFront.
    /// Calling orderFrontRegardless while collectionBehavior is empty forces a
    /// clean bind to the current active Space. canJoinAllSpaces and stationary are
    /// added afterwards so the panel appears on all desktops without animating
    /// during space-switch swipes.
    private func orderFrontOnActiveSpace(_ panel: NSPanel) {
        panel.collectionBehavior = []
        panel.orderFrontRegardless()
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    // MARK: - Public API

    var suppressesGlobalAutoHide: Bool {
        isMenuTracking || trayTransitionInFlight || colorPicker.isInFlight
            || route == .cdwn || preSelectionInFlight || rootState.isTrayPinned
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggleAnimated(on screen: NSScreen) {
        isVisible ? hideAnimated() : showAnimated(on: screen)
    }

    /// Trigger a capture directly (e.g. from a hotkey) without going through the panel UI.
    func captureDirectly(mode: CaptureMode, on screen: NSScreen) {
        currentScreen = screen
        updateScreenMetrics(for: screen)
        if mode == .selection {
            guard !preSelectionInFlight else { return }
            preSelectionInFlight = true
            selectionOverlay.onSelected = { [weak self] rect in
                guard let self else { return }
                self.preSelectionInFlight = false
                self.screenshot.captureRect(rect, preferredScreen: screen)
            }
            selectionOverlay.onCancelled = { [weak self] in
                self?.preSelectionInFlight = false
            }
            selectionOverlay.start(on: screen)
        } else {
            screenshot.capture(mode: mode, delaySeconds: 0, preferredScreen: screen)
        }
    }

    /// Trigger pick color directly (e.g. from a hotkey).
    func pickColorDirectly(on screen: NSScreen? = nil) {
        if let screen {
            currentScreen = screen
            updateScreenMetrics(for: screen)
        }
        pickColor()
    }

    func showAnimated(on screen: NSScreen) {
        currentScreen = screen
        updateScreenMetrics(for: screen)

        model.mode  = AppSettings.defaultCaptureMode
        model.delay = AppSettings.defaultTimerDelay

        if panel == nil { create() }
        guard let panel else { return }

        interactionState.isEnabled = false
        interactionState.contentVisibility = 0.0
        panel.alphaValue = 1

        // Position the panel on the target screen BEFORE ordering front.
        // macOS binds the window to a Space at the moment of orderFront based on
        // the current frame. Calling setFrame afterwards places it on whichever
        // Space the panel was on last time — especially noticeable after long
        // idle periods or wake-from-sleep.
        if metrics.hasNotch {
            panel.setFrame(frameForWidth(collapsedWidth, on: screen, height: trayPanelHeight), display: false)
        } else {
            let w = clampedWidth(currentWidthForCurrentRoute, on: screen)
            panel.setFrame(frameNoNotchHiddenAbove(width: w, on: screen, height: trayPanelHeight), display: false)
        }

        // Order front while collectionBehavior is empty so macOS binds the panel
        // to the current active Space, then add canJoinAllSpaces + stationary.
        // See orderFrontOnActiveSpace for the rationale.
        orderFrontOnActiveSpace(panel)

        if metrics.hasNotch {
            isExpanded = false

            let target = frameForWidth(clampedWidth(currentWidthForCurrentRoute, on: screen), on: screen, height: trayPanelHeight)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)

                withAnimation(.easeOut(duration: ctx.duration)) {
                    self.interactionState.contentVisibility = 1.0
                }
                panel.animator().setFrame(target, display: true)
            } completionHandler: { [weak self] in
                self?.interactionState.isEnabled = true
                self?.isExpanded = true
            }
        } else {
            isExpanded = true

            let w = clampedWidth(currentWidthForCurrentRoute, on: screen)
            let h = trayPanelHeight
            let visible = frameForWidth(w, on: screen, height: h)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)

                withAnimation(.easeOut(duration: ctx.duration)) {
                    self.interactionState.contentVisibility = 1.0
                }
                panel.animator().setFrame(visible, display: true)
            } completionHandler: { [weak self] in
                self?.interactionState.isEnabled = true
            }
        }
    }

    func hideAnimated(completion: (() -> Void)? = nil) {
        guard let panel, panel.isVisible else {
            completion?()
            return
        }
        rootState.isTrayPinned = false

        // Cancel any active countdown before hiding
        if route == .cdwn {
            cancelCountdownTimer()
            rootState.countdownVisible = 0.0
            rootState.countdownSeconds = 0
            rootState.countdownTotal = 0
            route = .main
        }

        interactionState.isEnabled = false

        guard let screen = (currentScreen ?? NSScreen.main ?? NSScreen.screens.first) else {
            panel.orderOut(nil)
            interactionState.isEnabled = true
            return
        }

        if route == .tray {
            hideTrayThenMain(panel: panel, screen: screen, completion: completion)
        } else {
            hideMainPanel(panel: panel, screen: screen, completion: completion)
        }
    }

    // Closing from Tray state: reverse of the open sequence.
    // Phase 1 — content hides instantly.
    // Phase 2 — shape morphs back to Main (Y axis).
    // Phase 3 — standard Main close animation (X axis).
    private func hideTrayThenMain(panel: NSPanel, screen: NSScreen, completion: (() -> Void)?) {
        // Instantly hide both tray and main content (otherwise main bleeds through in phase 2).
        rootState.trayContentVisible = 0.0
        interactionState.contentVisibility = 0.0

        DispatchQueue.main.asyncAfter(deadline: .now() + PanelTiming.oneFrameSettle) { [weak self, weak panel] in
            guard let self, let panel else { return }

            // Phase 2: morph shape tray → main (Y axis via progress, width unchanged).
            self.route = .main
            withAnimation(.easeIn(duration: PanelTiming.hideAnimation)) {
                self.rootState.progress = 0.0
            }

            // Phase 3: kick off the standard main-panel close.
            DispatchQueue.main.asyncAfter(deadline: .now() + PanelTiming.hideAnimation) { [weak self, weak panel] in
                guard let self, let panel else { return }
                self.rootState.trayContentVisible = 1.0  // reset for next open
                self.hideMainPanel(panel: panel, screen: screen, completion: completion)
            }
        }
    }

    private func hideMainPanel(panel: NSPanel, screen: NSScreen, completion: (() -> Void)?) {
        if metrics.hasNotch {
            isExpanded = false
            let target = frameForWidth(collapsedWidth, on: screen, height: trayPanelHeight)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = PanelTiming.hideAnimation
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

                withAnimation(.easeIn(duration: ctx.duration)) {
                    self.interactionState.contentVisibility = 0.0
                }
                panel.animator().setFrame(target, display: true)
            } completionHandler: { [weak self, weak panel] in
                panel?.orderOut(nil)
                self?.interactionState.isEnabled = true
                self?.isExpanded = false
                self?.route = .main
                self?.rootState.progress = 0.0
                self?.rootState.countdownVisible = 0.0
                self?.rootState.countdownSeconds = 0
                self?.rootState.countdownTotal = 0
                completion?()
            }
        } else {
            isExpanded = false
            let w = clampedWidth(currentWidthForCurrentRoute, on: screen)
            let h = trayPanelHeight
            let hidden = frameNoNotchHiddenAbove(width: w, on: screen, height: h)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = PanelTiming.hideAnimation
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)

                withAnimation(.easeIn(duration: ctx.duration)) {
                    self.interactionState.contentVisibility = 0.0
                }
                panel.animator().setFrame(hidden, display: true)
            } completionHandler: { [weak self, weak panel] in
                panel?.orderOut(nil)
                self?.interactionState.isEnabled = true
                self?.isExpanded = false
                self?.route = .main
                self?.rootState.progress = 0.0
                self?.rootState.countdownVisible = 0.0
                self?.rootState.countdownSeconds = 0
                self?.rootState.countdownTotal = 0
                completion?()
            }
        }
    }

    func isPointInsidePanel(_ point: NSPoint) -> Bool {
        guard let panel else { return false }
        return panel.frame.contains(point)
    }

    // MARK: - Panel lifecycle

    private func create() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: collapsedWidth, height: trayPanelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.appearance = NSAppearance(named: .darkAqua)

        panel.contentView = NSHostingView(rootView: makeRootView().managedLocale())
        self.panel = panel

        installEscMonitor()
    }

    private func installEscMonitor() {
        let escTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<NotchPanelController>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = controller.escEventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }

            guard type == .keyDown else { return Unmanaged.passUnretained(event) }
            guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(KeyCode.escape) else {
                return Unmanaged.passUnretained(event)
            }

            DispatchQueue.main.async {
                guard controller.isVisible else { return }
                controller.hideAnimated()
            }
            // Pass Esc through — don't consume it
            return Unmanaged.passUnretained(event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: escTapCallback,
            userInfo: selfPtr
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }

        escEventTap = tap
        escEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEscMonitor() {
        if let tap = escEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = escEventTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
                escEventTapSource = nil
            }
            escEventTap = nil
        }
    }

    private func makeRootView() -> NotchPanelRootView {
        NotchPanelRootView(
            rootState: rootState,
            interaction: interactionState,
            model: model,
            trayModel: trayModel,
            onClose: { [weak self] in self?.hideAnimated() },
            onCapture: { [weak self] mode, delay in
                guard let self else { return }
                if delay == .off {
                    let screen = self.currentScreen ?? NSScreen.main
                    if mode == .selection {
                        guard !self.preSelectionInFlight else { return }
                        self.preSelectionInFlight = true
                        self.hideAnimated { [weak self] in
                            guard let self else { return }
                            self.selectionOverlay.onSelected = { [weak self] rect in
                                guard let self else { return }
                                self.preSelectionInFlight = false
                                self.screenshot.captureRect(rect, preferredScreen: screen)
                            }
                            self.selectionOverlay.onCancelled = { [weak self] in
                                self?.preSelectionInFlight = false
                            }
                            self.selectionOverlay.start(on: screen ?? NSScreen.main ?? NSScreen.screens[0])
                        }
                    } else {
                        self.hideAnimated {
                            self.screenshot.capture(mode: mode, delaySeconds: 0, preferredScreen: screen)
                        }
                    }
                } else if mode == .screen {
                    self.startScreenCountdown(seconds: delay.seconds)
                } else {
                    self.launchPreSelection(mode: mode, seconds: delay.seconds)
                }
            },
            onToggleTray: { [weak self] in self?.switchToTray() },
            onPickColor: { [weak self] in self?.pickColor() },
            onModeDelayChanged: { [weak self] in self?.updateWidthForNoNotchIfNeeded() },
            onBack: { [weak self] in self?.switchToMain() },
            onTogglePin: { [weak self] in self?.rootState.isTrayPinned.toggle() },
            onStopCountdown: { [weak self] in self?.stopCountdown() },
            onCaptureNow: { [weak self] in self?.captureNowFromCountdown() }
        )
    }

    // MARK: - State routing

    func switchToTray() {
        if route == .tray { switchToMain() } else { transitionBetweenStates(.tray) }
    }

    func switchToMain() {
        guard route != .main else { return }
        rootState.isTrayPinned = false
        transitionBetweenStates(.main)
    }

    func transitionBetweenStates(_ targetRoute: NotchPanelRoute) {
        guard let panel else { return }
        guard let screen = currentScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        trayTransitionInFlight = true
        interactionState.isEnabled = false

        if targetRoute == .main {
            // Step 1: hide content in a separate render pass (without withAnimation).
            // Calling it together with withAnimation { progress = 0 } causes SwiftUI to
            // batch both objectWillChange notifications and apply the easeIn context to
            // both — opacity would then animate 1→0 over trayCloseMorph instead of
            // snapping instantly.
            rootState.trayContentVisible = 0.0

            // Step 2: give SwiftUI one render pass to process the hide before
            // starting the shape morph.
            DispatchQueue.main.asyncAfter(deadline: .now() + PanelTiming.oneFrameSettle) { [weak self, weak panel] in
                guard let self, let panel else { return }

                self.route = .main
                let targetFrame = self.frameForWidth(
                    self.clampedWidth(self.currentWidthForCurrentRoute, on: screen),
                    on: screen, height: self.trayPanelHeight
                )

                // X axis: panel width — NSAnimationContext
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = PanelTiming.trayCloseMorph
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    panel.animator().setFrame(targetFrame, display: true)
                } completionHandler: { [weak self] in
                    self?.trayTransitionInFlight = false
                    self?.interactionState.isEnabled = true
                    self?.rootState.trayContentVisible = 1.0  // reset for next open
                }

                // Y axis: shape morph — same curve, same runloop cycle as X
                withAnimation(.easeIn(duration: PanelTiming.trayCloseMorph)) {
                    self.rootState.progress = 0.0
                }
            }
        } else {
            // Opening: spring easing
            route = .tray
            let targetFrame = frameForWidth(
                clampedWidth(currentWidthForCurrentRoute, on: screen),
                on: screen, height: trayPanelHeight
            )
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = PanelTiming.trayCloseMorph
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.25, 1.0)
                panel.animator().setFrame(targetFrame, display: true)
            } completionHandler: { [weak self] in
                self?.trayTransitionInFlight = false
                self?.interactionState.isEnabled = true
            }
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    self.rootState.progress = 1.0
                }
            }
        }
    }

    // MARK: - Layout helpers that require panel access

    func updateScreenMetrics(for screen: NSScreen) {
        metrics = NotchMetrics.from(screen: screen)
    }

    func updateWidthForNoNotchIfNeeded() {
        guard !metrics.hasNotch else { return }
        guard let panel else { return }
        guard route == .main else { return }
        guard let screen = currentScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        let w = clampedWidth(expandedWidth, on: screen)
        let target = frameForWidth(w, on: screen)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }
    }
}
