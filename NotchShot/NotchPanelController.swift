import AppKit
import SwiftUI
import Combine

// MARK: - Interaction state

final class NotchPanelInteractionState: ObservableObject {
    @Published var isEnabled: Bool = true
    @Published var contentVisibility: Double = 1.0
}

// MARK: - Root state

enum NotchPanelRoute {
    case main
    case tray
    case cdwn
}

final class NotchPanelRootState: ObservableObject {
    @Published var route: NotchPanelRoute = .main
    @Published var metrics: NotchMetrics = .fallback()
    /// 0.0 = Main, 1.0 = Tray
    @Published var progress: CGFloat = 0.0
    /// Pre-faded to 0.0 before tray→main morph starts; reset to 1.0 after close completes
    @Published var trayContentVisible: CGFloat = 1.0
    /// 0.0 = Main visible, 1.0 = Countdown visible (crossfade, no morph)
    @Published var countdownVisible: CGFloat = 0.0
    @Published var countdownSeconds: Int = 0
    @Published var countdownTotal: Int = 0
}

private struct NotchPanelRootView: View {
    @ObservedObject var rootState: NotchPanelRootState
    @ObservedObject var interaction: NotchPanelInteractionState
    @ObservedObject var model: NotchPanelModel
    @ObservedObject var trayModel: NotchTrayModel

    let onClose: () -> Void
    let onCapture: (CaptureMode, CaptureDelay) -> Void
    let onToggleTray: () -> Void
    let onPickColor: () -> Void
    let onModeDelayChanged: () -> Void
    let onBack: () -> Void
    let onStopCountdown: () -> Void
    let onCaptureNow: () -> Void

    private var m: NotchMetrics { rootState.metrics }
    private var trayScrollHeight: CGFloat { 55 }
    private var trayH: CGFloat { m.panelHeight + trayScrollHeight }
    private var p: CGFloat { rootState.progress }

    var body: some View {
        ZStack(alignment: .top) {
            // Единый морфирующий фон
            PanelMorphShape(progress: p, pixel: m.pixel)
                .fill(Color.black)
                .compositingGroup()
                .frame(height: trayH)

            // Main — появляется только в последних ~60% морфа; скрывается при countdown
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
            .animation(.easeOut(duration: 0.16), value: rootState.countdownVisible)
            .allowsHitTesting(p < 0.5 && rootState.countdownVisible < 0.5)

            // Countdown — crossfade поверх Main, без изменения размера панели
            CountdownView(
                metrics: m,
                interaction: interaction,
                secondsRemaining: rootState.countdownSeconds,
                totalSeconds: rootState.countdownTotal,
                onStop: onStopCountdown,
                onCaptureNow: onCaptureNow
            )
            .opacity(rootState.countdownVisible)
            .animation(.easeOut(duration: 0.16), value: rootState.countdownVisible)
            .allowsHitTesting(rootState.countdownVisible >= 0.5)
            .frame(height: m.panelHeight)

            // Tray — появляется при p→1; content pre-fade через trayContentVisible
            // Два отдельных модификатора: SwiftUI трекает их независимо,
            // чтобы анимация progress не "затягивала" trayContentVisible
            NotchTrayView(
                metrics: m,
                trayModel: trayModel,
                onBack: onBack
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

    // MARK: Internal (accessible from extension files)
    var currentScreen: NSScreen?
    let rootState = NotchPanelRootState()
    let model = NotchPanelModel()
    let trayModel = NotchTrayModel()
    let screenshot = ScreenshotService()
    let colorPickerHUD = ColorPickerHUD()
    var activeSampler: ColorSampler?
    var colorSamplerInFlight: Bool = false

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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.switchToTray()
                }
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidBeginTracking),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidEndTracking),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        removeEscMonitor()
    }

    @objc
    private func menuDidBeginTracking() {
        isMenuTracking = true
    }

    @objc
    private func menuDidEndTracking() {
        isMenuTracking = false
    }

    // MARK: - Public API

    var suppressesGlobalAutoHide: Bool {
        isMenuTracking || trayTransitionInFlight || colorSamplerInFlight
            || route == .cdwn || preSelectionInFlight
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggleAnimated(on screen: NSScreen) {
        isVisible ? hideAnimated() : showAnimated(on: screen)
    }

    /// Trigger a capture directly (e.g. from a hotkey) without going through the panel UI.
    func captureDirectly(mode: CaptureMode, on screen: NSScreen) {
        currentScreen = screen
        updateScreenMetrics(for: screen)
        screenshot.capture(mode: mode, delaySeconds: 0, preferredScreen: screen)
    }

    /// Trigger pick color directly (e.g. from a hotkey).
    func pickColorDirectly() {
        pickColor()
    }

    func showAnimated(on screen: NSScreen) {
        currentScreen = screen
        updateScreenMetrics(for: screen)

        if panel == nil { create() }
        guard let panel else { return }

        interactionState.isEnabled = false
        interactionState.contentVisibility = 0.0
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        if metrics.hasNotch {
            isExpanded = false
            panel.setFrame(frameForWidth(collapsedWidth, on: screen, height: trayPanelHeight), display: true)

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
            let hidden = frameNoNotchHiddenAbove(width: w, on: screen, height: h)
            let visible = frameForWidth(w, on: screen, height: h)
            panel.setFrame(hidden, display: true)

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

        // Cancel any active countdown before hiding
        if route == .cdwn {
            countdownTimer?.invalidate()
            countdownTimer = nil
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

    // Закрытие из состояния Tray: обратная последовательность открытия.
    // Фаза 1 — контент скрывается мгновенно.
    // Фаза 2 — форма морфирует обратно в Main (Y-ось).
    // Фаза 3 — обычная анимация закрытия Main (X-ось).
    private func hideTrayThenMain(panel: NSPanel, screen: NSScreen, completion: (() -> Void)?) {
        // Мгновенно прячем и tray-контент, и main-контент (иначе он проявится в фазе 2)
        rootState.trayContentVisible = 0.0
        interactionState.contentVisibility = 0.0

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self, weak panel] in
            guard let self, let panel else { return }

            // Фаза 2: морф формы tray → main (без смены ширины — только Y через progress)
            self.route = .main
            withAnimation(.easeIn(duration: 0.18)) {
                self.rootState.progress = 0.0
            }

            // Фаза 3: запускаем стандартное закрытие main-панели
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self, weak panel] in
                guard let self, let panel else { return }
                self.rootState.trayContentVisible = 1.0  // сброс для следующего открытия
                self.hideMainPanel(panel: panel, screen: screen, completion: completion)
            }
        }
    }

    private func hideMainPanel(panel: NSPanel, screen: NSScreen, completion: (() -> Void)?) {
        if metrics.hasNotch {
            isExpanded = false
            let target = frameForWidth(collapsedWidth, on: screen, height: trayPanelHeight)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
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
                completion?()
            }
        } else {
            isExpanded = false
            let w = clampedWidth(currentWidthForCurrentRoute, on: screen)
            let h = trayPanelHeight
            let hidden = frameNoNotchHiddenAbove(width: w, on: screen, height: h)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.appearance = NSAppearance(named: .darkAqua)

        panel.contentView = NSHostingView(rootView: makeRootView())
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
            guard event.getIntegerValueField(.keyboardEventKeycode) == 53 else {
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
                    self.hideAnimated {
                        self.screenshot.capture(mode: mode, delaySeconds: 0, preferredScreen: screen)
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
        transitionBetweenStates(.main)
    }

    func transitionBetweenStates(_ targetRoute: NotchPanelRoute) {
        guard let panel else { return }
        guard let screen = currentScreen ?? NSScreen.main else { return }

        trayTransitionInFlight = true
        interactionState.isEnabled = false

        if targetRoute == .main {
            // Шаг 1: скрываем контент в отдельном рендер-пассе (без withAnimation).
            // Если вызвать сразу вместе с withAnimation { progress = 0 }, SwiftUI
            // батчит оба objectWillChange и применяет easeIn-контекст к обоим —
            // тогда opacity анимируется от 1→0 за 0.28s вместо мгновенного скачка.
            rootState.trayContentVisible = 0.0

            // Шаг 2: даём SwiftUI один рендер-пасс обработать скрытие контента,
            // только после этого запускаем морф формы.
            let closeDuration: TimeInterval = 0.28
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self, weak panel] in
                guard let self, let panel else { return }

                self.route = .main
                let targetFrame = self.frameForWidth(
                    self.clampedWidth(self.currentWidthForCurrentRoute, on: screen),
                    on: screen, height: self.trayPanelHeight
                )

                // X: ширина панели — NSAnimationContext
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = closeDuration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    panel.animator().setFrame(targetFrame, display: true)
                } completionHandler: { [weak self] in
                    self?.trayTransitionInFlight = false
                    self?.interactionState.isEnabled = true
                    self?.rootState.trayContentVisible = 1.0  // сброс для следующего открытия
                }

                // Y: морф формы — та же кривая, синхронно с X в том же runloop-цикле
                withAnimation(.easeIn(duration: closeDuration)) {
                    self.rootState.progress = 0.0
                }
            }
        } else {
            // Открытие: упругий spring как прежде
            route = .tray
            let targetFrame = frameForWidth(
                clampedWidth(currentWidthForCurrentRoute, on: screen),
                on: screen, height: trayPanelHeight
            )
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
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
