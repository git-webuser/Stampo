import AppKit
import SwiftUI
import Combine

// MARK: - Interaction state

final class NotchPanelInteractionState: ObservableObject {
    @Published var isEnabled: Bool = true
    @Published var contentVisibility: Double = 1.0
}

// MARK: - Root state

private enum NotchPanelRoute {
    case main
    case tray
    case cdwn
}

private final class NotchPanelRootState: ObservableObject {
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
    private var panel: NSPanel?
    private var currentScreen: NSScreen?

    private let interactionState = NotchPanelInteractionState()
    private let rootState = NotchPanelRootState()
    private let model = NotchPanelModel()
    private let trayModel = NotchTrayModel()
    private let screenshot = ScreenshotService()
    private let colorPickerHUD = ColorPickerHUD()
    private var activeSampler: ColorSampler?

    private var isMenuTracking: Bool = false
    private var trayTransitionInFlight: Bool = false
    private var colorSamplerInFlight: Bool = false
    private enum CaptureTarget {
        case screen
        case rect(CGRect)
        case windowID(CGWindowID)
    }

    private var countdownTimer: Timer?
    private var countdownCaptureTarget: CaptureTarget = .screen
    private var countdownScreen: NSScreen?

    private let selectionOverlay = SelectionOverlay()
    private let windowPickerOverlay = WindowPickerOverlay()
    private var preSelectionInFlight: Bool = false

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

    var suppressesGlobalAutoHide: Bool {
        isMenuTracking || trayTransitionInFlight || colorSamplerInFlight
            || route == .cdwn || preSelectionInFlight
    }

    private var metrics = NotchMetrics.fallback() {
        didSet {
            rootState.metrics = metrics
        }
    }

    private var route: NotchPanelRoute {
        get { rootState.route }
        set { rootState.route = newValue }
    }

    private var collapsedWidth: CGFloat { metrics.notchGap }

    private var expandedWidth: CGFloat {
        if metrics.hasNotch {
            let timerCell = metrics.timerMaxCellWidth

            let leftMin = metrics.edgeSafe
                + metrics.cellWidth + metrics.gap
                + metrics.cellWidth + metrics.gap
                + timerCell
                + metrics.leftMinToNotch

            let rightMin = metrics.rightMinFromNotch
                + metrics.cellWidth + metrics.gap
                + metrics.cellWidth + metrics.gap
                + metrics.captureButtonWidth
                + metrics.edgeSafe

            let shoulder = max(leftMin, rightMin)
            return collapsedWidth + 2 * shoulder
        }

        let left = metrics.edgeSafe
            + metrics.cellWidth + metrics.gap
            + metrics.cellWidth + metrics.gap
            + metrics.timerCellWidth(for: model.delay.shortLabel)

        let right = metrics.edgeSafe
            + metrics.cellWidth + metrics.gap
            + metrics.cellWidth + metrics.gap
            + metrics.captureButtonWidth

        return left + right
    }

    private(set) var isExpanded: Bool = false
    var isVisible: Bool { panel?.isVisible == true }

    // MARK: - Public

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

    // MARK: - Private

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

    private var escEventTap: CFMachPort?
    private var escEventTapSource: CFRunLoopSource?

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

    private var currentWidthForCurrentRoute: CGFloat {
        switch route {
        case .main:  return expandedWidth
        case .tray:  return trayWidth
        case .cdwn:  return expandedWidth
        }
    }

    // Панель всегда имеет высоту Tray — анимация через SwiftUI progress, не через setFrame
    private var trayScrollRowHeight: CGFloat { 55 }
    private var trayPanelHeight: CGFloat { metrics.panelHeight + trayScrollRowHeight }

    private func switchToTray() {
        if route == .tray { switchToMain() } else { transitionBetweenStates(.tray) }
    }

    private func switchToMain() {
        guard route != .main else { return }
        transitionBetweenStates(.main)
    }

    // MARK: - Countdown

    /// Screen mode: panel stays open, crossfade to countdown.
    private func startScreenCountdown(seconds: Int) {
        countdownCaptureTarget = .screen
        countdownScreen = currentScreen
        rootState.countdownSeconds = seconds
        rootState.countdownTotal = seconds
        route = .cdwn
        withAnimation(.easeOut(duration: 0.16)) {
            rootState.countdownVisible = 1.0
        }
        startCountdownTimer()
    }

    /// Selection/Window mode: hide panel, show pre-selection overlay, then show panel with countdown.
    private func launchPreSelection(mode: CaptureMode, seconds: Int) {
        guard !preSelectionInFlight else { return }
        preSelectionInFlight = true
        let screen = currentScreen ?? NSScreen.main ?? NSScreen.screens[0]

        hideAnimated { [weak self] in
            guard let self else { return }
            if mode == .selection {
                self.selectionOverlay.onSelected = { [weak self] rect in
                    guard let self else { return }
                    self.preSelectionInFlight = false
                    self.beginCountdownAfterPreSelection(target: .rect(rect), seconds: seconds, screen: screen)
                }
                self.selectionOverlay.onCancelled = { [weak self] in
                    self?.preSelectionInFlight = false
                }
                self.selectionOverlay.start(on: screen)
            } else {
                // .window
                self.windowPickerOverlay.onSelected = { [weak self] windowID in
                    guard let self else { return }
                    self.preSelectionInFlight = false
                    self.beginCountdownAfterPreSelection(target: .windowID(windowID), seconds: seconds, screen: screen)
                }
                self.windowPickerOverlay.onCancelled = { [weak self] in
                    self?.preSelectionInFlight = false
                }
                self.windowPickerOverlay.start(on: screen)
            }
        }
    }

    /// Called after pre-selection overlay completes: show panel in countdown state directly.
    private func beginCountdownAfterPreSelection(target: CaptureTarget, seconds: Int, screen: NSScreen) {
        countdownCaptureTarget = target
        countdownScreen = screen
        rootState.countdownSeconds = seconds
        rootState.countdownTotal = seconds
        // Set countdown visible instantly before panel appears (no crossfade needed)
        rootState.countdownVisible = 1.0
        route = .cdwn
        showAnimated(on: screen)
        startCountdownTimer()
    }

    private func startCountdownTimer() {
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.rootState.countdownSeconds > 1 {
                self.rootState.countdownSeconds -= 1
            } else {
                self.finishCountdown()
            }
        }
    }

    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        route = .main
        withAnimation(.easeOut(duration: 0.16)) {
            rootState.countdownVisible = 0.0
        }
        // Reset arc values only after the fade-out completes,
        // otherwise the arc would jump backwards while still visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.rootState.countdownSeconds = 0
            self?.rootState.countdownTotal = 0
        }
    }

    private func captureNowFromCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        let target = countdownCaptureTarget
        let screen = countdownScreen
        hideAnimated { [weak self] in
            self?.executeCapture(target: target, screen: screen)
        }
    }

    private func finishCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        let target = countdownCaptureTarget
        let screen = countdownScreen
        hideAnimated { [weak self] in
            self?.executeCapture(target: target, screen: screen)
        }
    }

    private func executeCapture(target: CaptureTarget, screen: NSScreen?) {
        switch target {
        case .screen:
            screenshot.capture(mode: .screen, delaySeconds: 0, preferredScreen: screen)
        case .rect(let cgRect):
            screenshot.captureRect(cgRect, preferredScreen: screen)
        case .windowID(let id):
            screenshot.captureWindowID(id, preferredScreen: screen)
        }
    }

    private func transitionBetweenStates(_ targetRoute: NotchPanelRoute) {
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

    private var trayWidth: CGFloat {
        // На устройствах с нотчем Tray использует ту же ширину что и Main —
        // контент скроллируется внутри, ширина панели не меняется.
        if metrics.hasNotch {
            return expandedWidth
        }

        let baseSide = metrics.edgeSafe
        let swatchWidth: CGFloat = metrics.buttonHeight + 2
        let shotWidth: CGFloat = swatchWidth * 1.6
        let spacing: CGFloat = 6

        let colorCount = trayModel.colors.count
        let shotCount = trayModel.items.count - colorCount
        let totalCount = max(1, trayModel.items.count)
        let contentWidth = CGFloat(colorCount) * swatchWidth
            + CGFloat(shotCount) * shotWidth
            + CGFloat(max(0, totalCount - 1)) * spacing

        let schemeControlWidth: CGFloat = 68
        let backButtonWidth: CGFloat = metrics.cellWidth

        return baseSide + backButtonWidth + metrics.gap + schemeControlWidth + metrics.gap + min(contentWidth, 300) + baseSide
    }

    @MainActor
    private func pickColor() {
        guard !colorSamplerInFlight else { return }
        colorSamplerInFlight = true

        let screen = currentScreen ?? NSScreen.main

        let launch = { [weak self] in
            guard let self else { return }

            let sampler = ColorSampler()
            self.activeSampler = sampler
            self.colorPickerHUD.beginSession(format: sampler.format)

            sampler.onColorChanged = { [weak self] color, position, magnifier in
                guard let self else { return }
                self.colorPickerHUD.setFormat(sampler.format)
                self.colorPickerHUD.update(color: color, cursorPosition: position, magnifier: magnifier)
            }

            sampler.onConfirmed = { [weak self] color in
                guard let self else { return }
                self.colorSamplerInFlight = false
                self.activeSampler = nil

                let sRGB = color.usingColorSpace(.sRGB) ?? color
                self.colorPickerHUD.showSuccess(color: sRGB, on: screen, autoHideAfter: 0.35)

                let formatted = self.colorPickerHUD.currentFormat.format(sRGB)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(formatted, forType: .string)

                self.trayModel.add(color: sRGB)
                // Reset route without showing panel
                self.route = .main
                self.rootState.progress = 0.0
            }

            sampler.onCancelled = { [weak self] in
                guard let self else { return }
                self.colorSamplerInFlight = false
                self.activeSampler = nil
                self.colorPickerHUD.hide()
                // Reset route without showing panel
                self.route = .main
                self.rootState.progress = 0.0
            }

            sampler.start()
        }

        if isVisible {
            // Panel is open — hide it first, then launch sampler
            CursorOverlay.hideCursorAfterMenuCloses()
            hideAnimated { launch() }
        } else {
            // Panel already hidden — launch sampler directly, no show/hide cycle
            launch()
        }
    }

    private func updateWidthForNoNotchIfNeeded() {
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

    private func updateScreenMetrics(for screen: NSScreen) {
        metrics = NotchMetrics.from(screen: screen)
    }

    private func clampedWidth(_ w: CGFloat, on screen: NSScreen) -> CGFloat {
        let maxW = screen.frame.width - 16
        return min(max(w, collapsedWidth), maxW)
    }

    private func frameForWidth(_ width: CGFloat, on screen: NSScreen?, height: CGFloat? = nil) -> NSRect {
        let h = height ?? metrics.panelHeight
        guard let screen else { return NSRect(x: 0, y: 0, width: width, height: h) }

        let sf = screen.frame
        let margin = snapToPixel(8, scale: metrics.scale)

        var x = sf.midX - width / 2
        x = max(sf.minX + margin, min(x, sf.maxX - margin - width))
        x = snapToPixel(x, scale: metrics.scale)

        let topInsetNoNotch = snapToPixel(metrics.outerSideInset, scale: metrics.scale)

        let y: CGFloat
        if metrics.hasNotch {
            // Панель прижата к верхнему краю экрана; при расширении растёт вниз
            y = snapToPixel(sf.maxY - h, scale: metrics.scale)
        } else {
            y = snapToPixel(screen.visibleFrame.maxY - h - topInsetNoNotch, scale: metrics.scale)
        }

        return NSRect(x: x, y: y, width: snapToPixel(width, scale: metrics.scale), height: snapToPixel(h, scale: metrics.scale))
    }

    private func frameNoNotchHiddenAbove(width: CGFloat, on screen: NSScreen?, height: CGFloat? = nil) -> NSRect {
        let h = height ?? metrics.panelHeight
        guard let screen else { return NSRect(x: 0, y: 0, width: width, height: h) }

        let sf = screen.frame
        let margin = snapToPixel(8, scale: metrics.scale)

        var x = sf.midX - width / 2
        x = max(sf.minX + margin, min(x, sf.maxX - margin - width))
        x = snapToPixel(x, scale: metrics.scale)

        let y = snapToPixel(sf.maxY + metrics.pixel, scale: metrics.scale)
        return NSRect(x: x, y: y, width: snapToPixel(width, scale: metrics.scale), height: snapToPixel(h, scale: metrics.scale))
    }
}

// MARK: - Pixel snapping

private func snapToPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
    let s = max(scale, 1)
    return (value * s).rounded() / s
}

// MARK: - Notch helpers

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let num = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(num.uint32Value)
    }
}
