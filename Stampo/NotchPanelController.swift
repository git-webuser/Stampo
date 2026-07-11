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

// MARK: - Panel state machine

/// Drives the controller through every visible phase of the panel.
/// `route` (in `NotchPanelRootState`) continues to feed the SwiftUI morph
/// animations; `PanelState` is the controller-side authority that
/// replaces the old isExpanded/trayTransitionInFlight flag pair.
enum PanelState {
    case hidden
    case showing
    case main
    case transitioning(to: TransitionTarget)
    case tray
    case hiding
    case countdown
    /// Panel hidden, an external selection overlay (rect or window) is up.
    /// The overlay session is part of the panel lifecycle so the hover
    /// controller knows to suppress auto-close while it's active.
    case preSelection(OverlayKind)
    /// WindowServer / Spaces binding is stale (sleep, wake, display
    /// reconfiguration, or a Space switch while hidden). The next show
    /// must rebind, and the hover controller cannot trust panel.isVisible.
    case stale(reason: StaleReason)
}

enum TransitionTarget { case tray, main }
enum OverlayKind { case selection, window }
enum StaleReason { case sleep, spaceChange, displayChange }

extension PanelState {
    /// True when the panel is at rest and visible, or in transit between
    /// visible states. The hover controller uses this to decide whether
    /// an outside click should auto-close the panel.
    var allowsAutoHide: Bool {
        switch self {
        case .transitioning, .countdown, .preSelection: return false
        case .hidden, .showing, .main, .tray, .hiding, .stale: return true
        }
    }

    /// True while a Space/sleep/display rebind is pending. Replaces the
    /// old `needsSpaceRebind` flag.
    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }
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
    let onCaptureText: () -> Void
    let onModeDelayChanged: () -> Void
    let onBack: () -> Void
    let onHidePanel: () -> Void
    let onTogglePin: () -> Void
    let onStopCountdown: () -> Void
    let onCaptureNow: () -> Void

    private var m: NotchMetrics { rootState.metrics }
    private var trayScrollHeight: CGFloat { 55 }
    private var trayH: CGFloat { m.panelHeight + trayScrollHeight }
    private var p: CGFloat { rootState.progress }

    var body: some View {
        // Notch style on a notch-less screen renders the whole panel at its 34pt
        // design size, then scales it uniformly (shape, buttons, fonts, paddings)
        // to fit the menu bar. The window frame is scaled to match in the
        // controller's frame* helpers. Real notch / rounded use panelScale == 1
        // and the unscaled path — no behaviour change.
        let s = m.panelScale
        if s == 1 {
            panelStack
        } else {
            GeometryReader { geo in
                panelStack
                    .frame(width: geo.size.width / s, height: geo.size.height / s, alignment: .top)
                    .scaleEffect(s, anchor: .topLeading)
            }
        }
    }

    private var panelStack: some View {
        // Panel content height at the current morph progress (Main → Tray).
        // Drives the no-notch background height and clips the tray content so its
        // lower rows are revealed in step with the growing panel — not before it
        // has opened.
        let revealH = m.panelHeight + p * (trayH - m.panelHeight)
        return ZStack(alignment: .top) {
            // Background. Only the real notch uses the morphing notch keyframes
            // (its viewBox flares blend into the physical notch). Notch-less
            // screens use fixed-radius shapes that grow in height with the tray
            // morph — so corners never distort the way the 536-wide keyframes do
            // when squished onto a narrow panel:
            //   • notch style: pinned to the top edge → square top corners flush
            //     with the screen edge, rounded bottom corners (a clean "tab").
            //   • rounded style: a full rounded rectangle below the menu bar.
            if m.hasNotch {
                PanelMorphShape(progress: p, pixel: m.pixel)
                    .fill(Color.black)
                    .compositingGroup()
                    .frame(height: trayH)
            } else {
                Group {
                    if m.pinnedToTopEdge {
                        // Notch tab with the notch's tapering bottom shoulders.
                        NotchTabShape()
                            .fill(Color.black)
                    } else {
                        RoundedRectangle(cornerRadius: m.panelRadius, style: .continuous)
                            .fill(Color.black)
                    }
                }
                .frame(height: revealH)
                .frame(height: trayH, alignment: .top)
            }

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
                onCaptureText: onCaptureText,
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
                onHidePanel: onHidePanel,
                onTogglePin: onTogglePin
            )
            .opacity(rootState.trayContentVisible)
            .opacity(p)
            .allowsHitTesting(p >= 0.5)
            // Reveal the tray content in step with the growing panel: clip it to
            // the current panel height so the lower rows don't show before the
            // background has expanded to cover them. revealH is a hair shorter
            // than the notch morph, so content reveals just behind the shape edge
            // (safe) rather than ahead of it. At rest (p=1) revealH == trayH.
            .mask(
                Color.black
                    .frame(height: revealH)
                    .frame(height: trayH, alignment: .top)
            )

            // Notch close zone — always topmost, width = notchGap, height = panelHeight.
            // Lets the user close the panel by tapping the notch pill even when the tray
            // is open and NotchPanelView hit-testing is disabled.
            if m.hasNotch {
                Color.clear
                    .frame(width: m.notchGap, height: m.panelHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { onClose() }
            }
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

    /// Authoritative panel state. All transitions go through here; the
    /// older isExpanded / trayTransitionInFlight flags were folded in.
    /// Note: setter is not `private(set)` because the countdown extension
    /// in NotchPanelCapture.swift needs to write to it. Only this file
    /// and its extensions should mutate `state`.
    var state: PanelState = .hidden {
        didSet { postMascotNotification() }
    }
    private var escEventTap: CFMachPort?
    private var escEventTapSource: CFRunLoopSource?
    private var notificationObservers: [NSObjectProtocol] = []

    /// True после sleep/wake/display-change/Space-switch, пока панель не была
    /// показана заново с принудительной перепривязкой к активному Space.
    /// Читается из NotchHoverController чтобы не уходить в «закрыть невидимую панель».
    /// Computed from `state == .stale(_)` after PR 3 refactor.
    var needsSpaceRebind: Bool { state.isStale }

    /// Монотонно возрастающий счётчик анимационных фаз. Каждая новая анимация
    /// фиксирует текущее значение; устаревшие completion handler'ы сравнивают
    /// с ним и завершаются без изменения состояния. Это предотвращает «мёртвые
    /// состояния» панели при быстрых открытие→закрытие или sleep прямо
    /// во время анимации.
    /// Сохраняется как defensive guard: `PanelState` обеспечивает основные
    /// инварианты, но stale completion'ы NSAnimation могут выстрелить уже
    /// после перехода в новое состояние; generation matching ловит этот случай.
    private var animationGeneration: Int = 0
    @discardableResult
    private func bumpGeneration() -> Int {
        animationGeneration &+= 1
        return animationGeneration
    }

    // MARK: - Mascot notifications

    /// Pending work item that posts .sleeping after a short debounce delay.
    /// Cancelled whenever a non-sleep state arrives, so transient .hidden states
    /// (e.g. panel hiding before a capture overlay starts) never reach the mascot.
    private var pendingSleepWorkItem: DispatchWorkItem?

    /// Single funnel for all mascot state posts.
    /// .sleeping is debounced by 150 ms so a rapid .hidden → .preSelection
    /// transition doesn't flash the mascot to sleep and back.
    func postMascotState(_ mascot: MascotState) {
        pendingSleepWorkItem?.cancel()
        pendingSleepWorkItem = nil
        if case .sleeping = mascot {
            let item = DispatchWorkItem {
                NotificationCenter.default.post(name: .mascotStateChanged, object: MascotState.sleeping)
            }
            pendingSleepWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
        } else {
            NotificationCenter.default.post(name: .mascotStateChanged, object: mascot)
        }
    }

    private func postMascotNotification() {
        switch state {
        case .countdown:                             postMascotState(.countdown)
        case .main, .tray, .showing, .preSelection: postMascotState(.awake)
        case .hidden:                               postMascotState(.sleeping)
        default:                                    break
        }
    }

    // MARK: - Debug trace

    func trace(_ event: String) {
        DebugTrace.add(
            "\(event) " +
            "state=\(state) route=\(route) " +
            "needsRebind=\(needsSpaceRebind) suppress=\(suppressesGlobalAutoHide) " +
            "gen=\(animationGeneration) " +
            "panel={\(PanelTrace.panelSummary(panel))} " +
            "screen={\(PanelTrace.screenSummary(currentScreen))} " +
            "\(PanelTrace.mouseSummary())"
        )
    }

    // MARK: Internal (accessible from extension files)
    var currentScreen: NSScreen?
    let rootState = NotchPanelRootState()
    let model = NotchPanelModel()
    let trayModel = NotchTrayModel()
    let screenshot = ScreenshotService()
    let colorPicker = ColorPickingCoordinator()
    let textCapture = TextCaptureCoordinator()

    enum CaptureTarget {
        case screen
        case rect(CGRect)
        case windowID(CGWindowID)
    }

    /// Active countdown session, if any. Replaces the three legacy fields
    /// (timer / target / screen) that used to live separately on the
    /// controller. `nil` ⇔ no countdown in progress.
    var activeCountdown: CountdownSession?

    let selectionOverlay = SelectionOverlay()
    let windowPickerOverlay = WindowPickerOverlay()

    /// True ⇔ `state` is `.preSelection(_)`. Kept as a helper so call sites
    /// don't need to repeat the pattern match. Replaces the
    /// preSelectionInFlight flag from PR 2.
    var isInPreSelection: Bool {
        if case .preSelection = state { return true }
        return false
    }

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
        colorPicker.hidePanel = { [weak self] completion in self?.hideAnimated(reason: .colorPickerStart, completion: completion) }
        colorPicker.addColor  = { [weak self] color in self?.trayModel.add(color: color) }
        colorPicker.resetRoute = { [weak self] in
            self?.route = .main
            self?.rootState.progress = 0.0
        }
        colorPicker.hideCursorBeforeHide = { CursorOverlay.hideCursorAfterMenuCloses() }
        colorPicker.onFlightChanged = { [weak self] inFlight in
            // Only post .sleeping when flight ends via cancellation.
            // The confirmed path posts .celebrating via onPickConfirmed instead.
            self?.postMascotState(inFlight ? .colorPicking(.leftCenter) : .sleeping)
        }
        colorPicker.onPickConfirmed = { [weak self] in
            self?.postMascotState(.celebrating)
        }
        colorPicker.onCursorMoved = { point in
            NotificationCenter.default.post(name: .mascotCursorMoved, object: NSValue(point: point))
        }
        textCapture.addText = { [weak self] text in self?.trayModel.add(text: text) }
        screenshot.onCaptured = { [weak self] url in
            self?.trayModel.add(screenshotURL: url)
            // Clear preSelection so the next capture attempt isn't blocked.
            if case .preSelection = self?.state { self?.state = .hidden }
            self?.postMascotState(.celebrating)
        }
        screenshot.onCancelled = { [weak self] in
            if case .preSelection = self?.state { self?.state = .hidden }
            self?.postMascotState(.sleeping)
        }
        screenshot.onThumbnailTapped = { [weak self] in
            guard let self else { return }
            // Тот же guard что в toggleAnimated: после sleep/Space-switch AppKit
            // может считать панель isVisible, хотя пользователь её не видит.
            if self.isVisible && !self.needsSpaceRebind {
                self.switchToTray()
            } else {
                guard let screen = self.currentScreen ?? NSScreen.main else { return }
                self.showAnimated(on: screen, forceRebind: self.needsSpaceRebind)
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
        // A Space switch can leave WindowServer's binding for a long-lived
        // non-activating NSPanel corrupted even though AppKit still reports
        // isVisible=true and canJoinAllSpaces. Re-ordering that same window does
        // not repair the binding. Recreate it instead: visible UI is restored
        // immediately, while a hidden panel is rebuilt lazily on the next show.
        let t3 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.trace("spaceDidChange.begin")
            if case .hiding = self.state {
                // Respect a close already in progress; rebuilding here would
                // cancel the hide animation and unexpectedly reopen the panel.
                self.markPanelSpaceBindingStale()
            } else if let panel = self.panel, panel.isVisible {
                self.recreateVisiblePanelAfterSpaceChange(from: panel)
            } else {
                self.markPanelSpaceBindingStale()
            }
        }

        // После сна, пробуждения или перестройки дисплеев WindowServer может
        // сохранить у старого NSPanel устаревшую Space-привязку, которую AppKit
        // не исправляет самостоятельно. Самый надёжный способ — пересоздать
        // панель при следующем показе вместо того, чтобы «лечить» старую.
        let onSleepWake: (Notification) -> Void = { [weak self] _ in
            self?.invalidatePanelAfterEnvironmentChange(reason: .sleep)
        }
        let onDisplayChange: (Notification) -> Void = { [weak self] _ in
            self?.invalidatePanelAfterEnvironmentChange(reason: .displayChange)
        }
        let t4 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main, using: onSleepWake)
        let t5 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main, using: onSleepWake)
        let t6 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main, using: onSleepWake)
        let t7 = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main, using: onDisplayChange)
        // Edited screenshots saved from the annotation editor join the tray.
        let t8 = NotificationCenter.default.addObserver(
            forName: .editorDidSaveImage,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.object as? URL else { return }
            self?.trayModel.add(screenshotURL: url)
        }

        notificationObservers = [t1, t2, t3, t4, t5, t6, t7, t8]
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
        activeCountdown?.timer?.invalidate()
        activeCountdown = nil
    }

    /// Выводит панель на текущий активный Space.
    ///
    /// Панель создаётся с `.canJoinAllSpaces` и должна присутствовать на всех
    /// рабочих столах. Раньше здесь был трюк `.moveToActiveSpace` → orderFront →
    /// `.canJoinAllSpaces`, который ломался: `.moveToActiveSpace` переносит окно
    /// только при АКТИВАЦИИ приложения, а это `nonactivatingPanel`, выводимый
    /// через `orderFrontRegardless()` без активации. Перенос не срабатывал, зато
    /// `.canJoinAllSpaces` снимался — и окно залипало на одном Space. Поэтому
    /// просто переутверждаем `.canJoinAllSpaces` и выводим панель вперёд:
    /// окно остаётся на всех Space и появляется на том, что активен сейчас.
    /// `.stationary` (восстановлен в `f02100f`) убирает «дыру» при анимации
    /// Mission Control.
    private func orderFrontOnActiveSpace(_ panel: NSPanel) {
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.orderFrontRegardless()
    }

    /// Replaces a visible panel with a fresh WindowServer window after the
    /// active Space changes. The existing NSHostingView is moved to the new
    /// window instead of rebuilding the SwiftUI hierarchy. This preserves all
    /// view-local state, including NSScrollView's exact content offset.
    private func recreateVisiblePanelAfterSpaceChange(from oldPanel: NSPanel) {
        let restoredState: PanelState
        switch state {
        case .countdown:
            restoredState = .countdown
        default:
            restoredState = route == .tray ? .tray : .main
        }

        bumpGeneration() // invalidate completions that still reference oldPanel
        let retainedContentView = oldPanel.contentView
        oldPanel.orderOut(nil)
        // Detach before close so AppKit does not tear down the hosting tree.
        oldPanel.contentView = nil
        oldPanel.close()
        panel = nil
        removeEscMonitor()

        create(reusing: retainedContentView)
        guard let panel,
              let screen = currentScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            state = .stale(reason: .spaceChange)
            trace("spaceDidChange.visible.recreate.failed")
            return
        }

        updateScreenMetrics(for: screen)
        let width = clampedWidth(currentWidthForCurrentRoute, on: screen)
        panel.setFrame(
            frameForWidth(width, on: screen, height: trayPanelHeight),
            display: false
        )
        panel.alphaValue = 1
        interactionState.contentVisibility = 1
        interactionState.isEnabled = true
        state = restoredState
        orderFrontOnActiveSpace(panel)
        trace("spaceDidChange.visible.recreate.done")
    }

    /// Помечает Space-привязку панели устаревшей и аккуратно прячет её.
    /// Используется при переключении Space пока панель скрыта.
    private func markPanelSpaceBindingStale() {
        trace("markStale.begin")
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        removeEscMonitor()
        // Сброс состояния, чтобы следующий show начался из чистого Main.
        state = .stale(reason: .spaceChange)
        interactionState.isEnabled = true
        route = .main
        rootState.progress = 0.0
        rootState.countdownVisible = 0.0
    }

    /// Полностью уничтожает NSPanel после sleep/wake/display-change.
    /// Пересоздание при следующем show — единственный способ гарантированно
    /// избавиться от устаревшей WindowServer / Spaces привязки.
    private func invalidatePanelAfterEnvironmentChange(reason: StaleReason = .sleep) {
        trace("invalidateEnvironment.begin reason=\(reason)")
        bumpGeneration()

        // Отменяем любые активные overlay-сессии: если sleep/wake случился во время
        // выбора области, окна или цвета, preSelection / colorPicker.isInFlight
        // зависнут и через suppressesGlobalAutoHide сделают панель неуправляемой.
        selectionOverlay.cancel()
        windowPickerOverlay.cancel()
        colorPicker.cancel()
        textCapture.cancel()
        screenshot.cancelCurrentCapture()

        activeCountdown?.timer?.invalidate()
        activeCountdown = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        removeEscMonitor()
        state = .stale(reason: reason)
        interactionState.isEnabled = true
        route = .main
        rootState.progress = 0.0
        rootState.countdownVisible = 0.0
        rootState.countdownSeconds = 0
        rootState.countdownTotal = 0
        rootState.trayContentVisible = 1.0
        rootState.isTrayPinned = false
    }

    // MARK: - Public API

    var suppressesGlobalAutoHide: Bool {
        !state.allowsAutoHide
            || isMenuTracking
            || colorPicker.isInFlight
            || rootState.isTrayPinned
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggleAnimated(on screen: NSScreen) {
        // После sleep/wake/Space-switch AppKit может считать панель isVisible==true,
        // хотя пользователь её не видит на текущем рабочем столе. В таком случае
        // не уходим в hideAnimated — принудительно показываем заново на активном Space.
        if isVisible && !needsSpaceRebind {
            hideAnimated(reason: .hotkeyToggle)
        } else {
            showAnimated(on: screen, forceRebind: needsSpaceRebind)
        }
    }

    /// Trigger a capture directly (e.g. from a hotkey) without going through the panel UI.
    func captureDirectly(mode: CaptureMode, on screen: NSScreen) {
        currentScreen = screen
        updateScreenMetrics(for: screen)
        if mode == .selection {
            guard !isInPreSelection else { return }
            state = .preSelection(.selection)
            selectionOverlay.onSelected = { [weak self] rect in
                guard let self else { return }
                self.state = .hidden
                // The overlay panel was just orderOut(nil)'d, but WindowServer
                // still has it in the framebuffer for a frame or two. Without a
                // small delay screencapture(1) fires before the dim/cursor
                // overlay is gone and the resulting image includes them.
                // Panel-mode area capture doesn't hit this because the panel's
                // hideAnimated completion provides a much longer buffer.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.screenshot.captureRect(rect, preferredScreen: screen)
                }
            }
            selectionOverlay.onCancelled = { [weak self] in
                self?.state = .hidden
            }
            selectionOverlay.start(on: screen)
        } else if mode == .window {
            guard !isInPreSelection else { return }
            state = .preSelection(.window)
            screenshot.capture(mode: mode, delaySeconds: 0, preferredScreen: screen)
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

    func showAnimated(on screen: NSScreen, forceRebind: Bool = false) {
        trace("showAnimated.begin forceRebind=\(forceRebind) targetScreen={\(PanelTrace.screenSummary(screen))}")
        currentScreen = screen
        updateScreenMetrics(for: screen)

        model.mode  = AppSettings.defaultCaptureMode
        model.delay = AppSettings.defaultTimerDelay

        if panel == nil { create() }
        guard let panel else { return }

        // Environment/Space invalidation normally destroys the old NSPanel, so
        // create() above gives WindowServer a fresh Space binding. Keep orderOut
        // as a defensive fallback if a stale state ever arrives with a panel.
        if forceRebind {
            panel.orderOut(nil)
            // state.isStale is cleared automatically when we transition to
            // .showing below — no separate flag write needed.
        }

        state = .showing
        let gen = bumpGeneration()
        interactionState.isEnabled = false
        interactionState.contentVisibility = 0.0
        panel.alphaValue = 1

        // Позиционируем ДО orderFront: macOS привязывает окно к Space в момент
        // orderFront, исходя из текущего фрейма. setFrame после — окно окажется
        // на прошлом Space (особенно после долгого idle и выхода из сна).
        if metrics.hasNotch {
            panel.setFrame(frameForWidth(collapsedWidth, on: screen, height: trayPanelHeight), display: false)
        } else {
            // Reveal by descending from above the top edge — the exact reverse of
            // the close animation. The notch tab starts just the content height
            // above so the whole descent is visible (see frameNotchTabHidden);
            // the rounded style slides down at full width from fully above.
            let w = clampedWidth(currentWidthForCurrentRoute, on: screen)
            let start = metrics.pinnedToTopEdge
                ? frameNotchTabHidden(width: w, on: screen)
                : frameNoNotchHiddenAbove(width: w, on: screen, height: trayPanelHeight)
            panel.setFrame(start, display: false)
        }

        // .moveToActiveSpace перед orderFront гарантирует привязку к текущему
        // Space; .canJoinAllSpaces после — расширяет присутствие на все Desktop.
        // Подробнее — в orderFrontOnActiveSpace.
        orderFrontOnActiveSpace(panel)
        trace("showAnimated.afterOrderFront")

        if metrics.hasNotch {
            let target = frameForWidth(clampedWidth(currentWidthForCurrentRoute, on: screen), on: screen, height: trayPanelHeight)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)

                withAnimation(.easeOut(duration: ctx.duration)) {
                    self.interactionState.contentVisibility = 1.0
                }
                panel.animator().setFrame(target, display: true)
            } completionHandler: { [weak self] in
                guard let self, self.animationGeneration == gen else {
                    self?.trace("showAnimated.completion.genMismatch gen=\(gen)")
                    return
                }
                self.interactionState.isEnabled = true
                // Only finalise to .main if nothing reassigned state during
                // the animation (e.g. countdown overlay set .countdown).
                if case .showing = self.state { self.state = .main }
                self.trace("showAnimated.completion.done")
            }
        } else {
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
                guard let self, self.animationGeneration == gen else {
                    self?.trace("showAnimated.completion.genMismatch gen=\(gen)")
                    return
                }
                self.interactionState.isEnabled = true
                // Only finalise to .main if nothing reassigned state during
                // the animation (e.g. countdown overlay set .countdown).
                if case .showing = self.state { self.state = .main }
                self.trace("showAnimated.completion.done")
            }
        }
    }

    func hideAnimated(reason: PanelHideReason = .unknown, completion: (() -> Void)? = nil) {
        trace("hideAnimated.begin reason=\(reason.rawValue)")
        guard let panel, panel.isVisible else {
            trace("hideAnimated.skip reason=\(reason.rawValue)")
            completion?()
            return
        }
        rootState.isTrayPinned = false

        // Cancel any active countdown before hiding
        if case .countdown = state {
            cancelCountdownTimer()
            activeCountdown = nil
            rootState.countdownVisible = 0.0
            rootState.countdownSeconds = 0
            rootState.countdownTotal = 0
            route = .main
        }

        let wasTray = (route == .tray)
        state = .hiding
        interactionState.isEnabled = false
        bumpGeneration()

        guard let screen = (currentScreen ?? NSScreen.main ?? NSScreen.screens.first) else {
            panel.orderOut(nil)
            interactionState.isEnabled = true
            return
        }

        if wasTray {
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
        let gen = animationGeneration
        // Instantly hide both tray and main content (otherwise main bleeds through in phase 2).
        rootState.trayContentVisible = 0.0
        interactionState.contentVisibility = 0.0

        DispatchQueue.main.asyncAfter(deadline: .now() + PanelTiming.oneFrameSettle) { [weak self, weak panel] in
            guard let self, let panel, self.animationGeneration == gen else { return }

            // Phase 2: morph shape tray → main (Y axis via progress, width unchanged).
            self.route = .main
            withAnimation(.easeIn(duration: PanelTiming.hideAnimation)) {
                self.rootState.progress = 0.0
            }

            // Phase 3: kick off the standard main-panel close.
            DispatchQueue.main.asyncAfter(deadline: .now() + PanelTiming.hideAnimation) { [weak self, weak panel] in
                guard let self, let panel, self.animationGeneration == gen else { return }
                self.rootState.trayContentVisible = 1.0  // reset for next open
                self.hideMainPanel(panel: panel, screen: screen, completion: completion)
            }
        }
    }

    private func hideMainPanel(panel: NSPanel, screen: NSScreen, completion: (() -> Void)?) {
        let gen = animationGeneration
        if metrics.hasNotch {
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
                guard let self, self.animationGeneration == gen else {
                    self?.trace("hideMainPanel.completion.genMismatch gen=\(gen)")
                    return
                }
                self.state = .hidden
                self.interactionState.isEnabled = true
                self.route = .main
                self.rootState.progress = 0.0
                self.rootState.isTrayPinned = false
                self.rootState.countdownVisible = 0.0
                self.rootState.countdownSeconds = 0
                self.rootState.countdownTotal = 0
                self.trace("hideMainPanel.completion.orderOut")
                completion?()
            }
        } else {
            let w = clampedWidth(currentWidthForCurrentRoute, on: screen)
            let h = trayPanelHeight
            // Mirror of the reveal: notch tab rises just the content height (so the
            // close is fully visible), rounded style slides up fully above.
            let hidden = metrics.pinnedToTopEdge
                ? frameNotchTabHidden(width: w, on: screen)
                : frameNoNotchHiddenAbove(width: w, on: screen, height: h)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = PanelTiming.hideAnimation
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)

                withAnimation(.easeIn(duration: ctx.duration)) {
                    self.interactionState.contentVisibility = 0.0
                }
                panel.animator().setFrame(hidden, display: true)
            } completionHandler: { [weak self, weak panel] in
                panel?.orderOut(nil)
                guard let self, self.animationGeneration == gen else {
                    self?.trace("hideMainPanel.completion.genMismatch gen=\(gen)")
                    return
                }
                self.state = .hidden
                self.interactionState.isEnabled = true
                self.route = .main
                self.rootState.progress = 0.0
                self.rootState.isTrayPinned = false
                self.rootState.countdownVisible = 0.0
                self.rootState.countdownSeconds = 0
                self.rootState.countdownTotal = 0
                self.trace("hideMainPanel.completion.orderOut")
                completion?()
            }
        }
    }

    func isPointInsidePanel(_ point: NSPoint) -> Bool {
        guard let panel else { return false }
        return panel.frame.contains(point)
    }

    // MARK: - Panel lifecycle

    private func create(reusing contentView: NSView? = nil) {
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

        panel.contentView = contentView
            ?? NSHostingView(rootView: makeRootView().managedLocale())
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
                controller.hideAnimated(reason: .escKey)
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
            onClose: { [weak self] in self?.hideAnimated(reason: .closeButton) },
            onCapture: { [weak self] mode, delay in
                guard let self else { return }
                if delay == .off {
                    let screen = self.currentScreen ?? NSScreen.main
                    if mode == .selection {
                        guard !self.isInPreSelection else { return }
                        self.hideAnimated(reason: .captureStart) { [weak self] in
                            guard let self else { return }
                            // hideAnimated set state to .hidden; promote to
                            // .preSelection now that the overlay is taking over.
                            self.state = .preSelection(.selection)
                            self.selectionOverlay.onSelected = { [weak self] rect in
                                guard let self else { return }
                                self.state = .hidden
                                self.screenshot.captureRect(rect, preferredScreen: screen)
                            }
                            self.selectionOverlay.onCancelled = { [weak self] in
                                self?.state = .hidden
                            }
                            self.selectionOverlay.start(on: screen ?? NSScreen.main ?? NSScreen.screens[0])
                        }
                    } else {
                        self.hideAnimated(reason: .captureStart) { [weak self] in
                            guard let self else { return }
                            // For window mode the user still has to pick a window,
                            // so promote to .preSelection to keep the mascot awake.
                            if mode == .window {
                                self.state = .preSelection(.window)
                            }
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
            onCaptureText: { [weak self] in self?.captureText() },
            onModeDelayChanged: { [weak self] in self?.updateWidthForNoNotchIfNeeded() },
            onBack: { [weak self] in self?.switchToMain() },
            onHidePanel: { [weak self] in self?.hideAnimated(reason: .closeButton) },
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

        // Coalesce re-entrant toggles: ignore a new tray morph while one is still
        // in flight. Overlapping transitions orphan each other's completion
        // handlers (generation mismatch), which left brief half-morphed/stuck
        // states during rapid clicking. hideAnimated/showAnimated (Esc, hotkey,
        // outside-click) are not routed through here, so they can still interrupt.
        if case .transitioning = state { return }

        let gen = bumpGeneration()
        let target: TransitionTarget = (targetRoute == .tray) ? .tray : .main
        state = .transitioning(to: target)
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
                guard let self, let panel, self.animationGeneration == gen else { return }

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
                    guard let self, self.animationGeneration == gen else { return }
                    self.state = .main
                    self.interactionState.isEnabled = true
                    self.rootState.trayContentVisible = 1.0  // reset for next open
                }

                // Y axis: shape morph — same curve, same runloop cycle as X
                withAnimation(.easeIn(duration: PanelTiming.trayCloseMorph)) {
                    self.rootState.progress = 0.0
                }
            }
        } else {
            // Opening: spring easing
            route = .tray
            // Ensure the tray content is visible on open. A rapid open→close can
            // strand trayContentVisible at 0 — the close pre-fades it to 0 and its
            // reset back to 1 is generation-gated, so an interrupted close skips
            // the reset; without this line the next open showed only empty bg.
            rootState.trayContentVisible = 1.0
            let targetFrame = frameForWidth(
                clampedWidth(currentWidthForCurrentRoute, on: screen),
                on: screen, height: trayPanelHeight
            )
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = PanelTiming.trayCloseMorph
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.25, 1.0)
                panel.animator().setFrame(targetFrame, display: true)
            } completionHandler: { [weak self] in
                guard let self, self.animationGeneration == gen else { return }
                self.state = .tray
                self.interactionState.isEnabled = true
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
        // Keep the window at the full tray height — only the width may change here.
        // Animating height collapsed the panel vertically (it was created/shown at
        // trayPanelHeight but this used the default panelHeight).
        let target = frameForWidth(w, on: screen, height: trayPanelHeight)

        // Resize instantly: the content (timer cell) reflows with no animation
        // (`.animation(nil, value: model.delay)`), so a 0.12s window animation
        // lagged behind the snapped content and looked like an abrupt collapse.
        // Snapping the window in sync keeps the background flush with the buttons.
        panel.setFrame(target, display: true)
    }
}
