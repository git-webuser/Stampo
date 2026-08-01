import AppKit
import CoreGraphics
import Carbon
import OSLog

final class NotchHoverController: NSObject {
    private let panel: NotchPanelController

    /// True если мониторы кликов для области челки установлены.
    /// Читается из GeneralSettingsView для отображения статуса.
    /// (Имя историческое — с прототипа notch-click-monitors кликом занимаются
    /// NSEvent-мониторы, Input Monitoring больше не нужен.)
    static private(set) var isEventTapInstalled: Bool = false

    private var statusItem: NSStatusItem?
    /// PROTOTYPE: пара NSEvent-мониторов вместо CGEventTap. Глобальные
    /// mouse-мониторы НЕ требуют Input Monitoring (в отличие от CGEventTap,
    /// которому оно нужно даже для мыши). Global видит клики в чужих окнах и
    /// системных зонах (меню-бар/челка); local — клики по окнам самого Stampo
    /// (глобальный монитор их не получает).
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var hotKeyHandlerRef: EventHandlerRef?

    /// Live Carbon hotkey refs, keyed by action. Only enabled (non-nil combo)
    /// actions appear here.
    private var hotKeyRefs: [HotkeyAction: EventHotKeyRef] = [:]

    // Control + Option + Command + N  →  toggle panel
    private let hotKeyCode: UInt32 = UInt32(kVK_ANSI_N)
    private let hotKeyModifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey)

    init(panel: NotchPanelController) {
        self.panel = panel
        super.init()
    }

    deinit {
        stop()
    }

    func start() {
        stop()
        installStatusItem()
        installHotKey()
        installEventTap()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onSettingsDidClose),
            name: .settingsWindowDidClose,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onUserDefaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onMascotStateChanged(_:)),
            name: .mascotStateChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onMascotCursorMoved(_:)),
            name: .mascotCursorMoved,
            object: nil
        )
        NotificationCenter.default.addObserver(
            forName: .hotkeyRecordingChanged, object: nil, queue: .main
        ) { [weak self] note in
            self?.isRecordingHotkey = (note.object as? Bool) ?? false
        }
        // NSEvent-мониторы не могут «умереть» от смены сигнатуры или отзыва
        // TCC (разрешений они не требуют), так что 4-секундный health-поллинг
        // прежней tap-эры больше не нужен. Дешёвая самопроверка на пробуждении
        // остаётся как страховка.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(reconcileNotchClickAvailability),
            name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    /// True while the shortcut recorder is armed — suppresses hotkey actions.
    private var isRecordingHotkey = false

    func stop() {
        NotificationCenter.default.removeObserver(self, name: .settingsWindowDidClose, object: nil)
        NotificationCenter.default.removeObserver(self, name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: .mascotStateChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: .mascotCursorMoved, object: nil)
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.didWakeNotification, object: nil)
        uninstallEventTap()
        uninstallHotKey()
        uninstallStatusItem()
    }

    @objc private func onSettingsDidClose() {
        reinstallHotKeysIfNeeded()
    }

    /// Самовосстановление после пробуждения: NSEvent-мониторы не зависят от
    /// TCC и не отключаются системой, так что доступность равна «мониторы
    /// установлены» — если их вдруг нет, ставим заново.
    @objc private func reconcileNotchClickAvailability() {
        if globalClickMonitor == nil || localClickMonitor == nil {
            uninstallEventTap()
            installEventTap()
        }
    }

    @objc private func onUserDefaultsChanged() {
        reinstallHotKeysIfNeeded()
        updateStatusItemMenuTitles()
    }

    @objc private func onMascotStateChanged(_ note: Notification) {
        guard let state = note.object as? MascotState else { return }
        mascotView?.setState(state)
    }

    @objc private func onMascotCursorMoved(_ note: Notification) {
        guard let val = note.object as? NSValue else { return }
        let point = val.pointValue
        let dir = eyeDirection(for: point)
        mascotView?.setState(.colorPicking(dir))
    }

    private func eyeDirection(for point: NSPoint) -> EyeDirection {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        let frame  = screen?.frame ?? NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let relX = (point.x - frame.minX) / frame.width
        // The point arrives from ColorSampler as NSEvent.mouseLocation — already
        // AppKit coordinates (y=0 at bottom), same space as NSScreen.frame.
        // No CG→AppKit flip needed: cursor at the top → mascot looks up.
        let relY = (point.y - frame.minY) / frame.height  // 0 = bottom, 1 = top
        let isLeft = relX < 0.5
        if relY > 0.66 {
            return isLeft ? .leftUp    : .rightUp
        } else if relY < 0.33 {
            return isLeft ? .leftDown  : .rightDown
        } else {
            return isLeft ? .leftCenter : .rightCenter
        }
    }

    private var lastHotkeyState: [HotkeyAction: HotkeyCombo?] = [:]

    private func reinstallHotKeysIfNeeded() {
        let current = HotkeyAction.allCases.reduce(into: [HotkeyAction: HotkeyCombo?]()) {
            $0[$1] = $1.combo
        }
        guard current != lastHotkeyState else { return }
        uninstallHotKey()
        installHotKey()
    }

    private var statusItemSettingsItem: NSMenuItem?
    private var statusItemQuitItem: NSMenuItem?
    private var mascotView: MascotStatusView?

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 30)
        statusItem = item

        guard let button = item.button else { return }
        button.image = nil
        button.imagePosition = .noImage

        let mascot = MascotStatusView(frame: NSRect(x: 4, y: 2, width: 22, height: 18))
        button.addSubview(mascot)
        mascotView = mascot

        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: LocaleManager.shared.string("Settings"),
            action: #selector(statusMenuSettingsTapped),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        statusItemSettingsItem = settingsItem

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: LocaleManager.shared.string("Quit Stampo"),
            action: #selector(statusMenuQuitTapped),
            keyEquivalent: ""
        )
        quitItem.target = self
        menu.addItem(quitItem)
        statusItemQuitItem = quitItem

        item.menu = menu
    }

    private func uninstallStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        statusItemSettingsItem = nil
        statusItemQuitItem = nil
        mascotView = nil
    }

    private func updateStatusItemMenuTitles() {
        statusItemSettingsItem?.title = LocaleManager.shared.string("Settings")
        statusItemQuitItem?.title     = LocaleManager.shared.string("Quit Stampo")
    }

    @objc private func statusMenuSettingsTapped() {
        SettingsWindowController.shared.open()
    }

    @objc private func statusMenuQuitTapped() {
        NSApp.terminate(nil)
    }

    private func installHotKey() {
        HotkeyAction.migrateIfNeeded()
        HotkeyAction.migrateScanMergeIfNeeded()
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let userData, let eventRef else { return noErr }

            let controller = Unmanaged<NotchHoverController>.fromOpaque(userData).takeUnretainedValue()
            var incomingHotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &incomingHotKeyID
            )
            guard status == noErr else { return noErr }
            // Dispatch only our own action hotkeys ('STMP'): the Esc hotkey
            // (EscapeHotkeyCenter, 'STES') also uses id 1, which would
            // otherwise collide with togglePanel if its event ever reaches
            // this handler.
            guard incomingHotKeyID.signature == fourCharCode("STMP") else {
                return OSStatus(eventNotHandledErr)
            }

            controller.handleHotKey(incomingHotKeyID)
            return noErr
        }

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &hotKeyHandlerRef
        )
        guard handlerStatus == noErr else { return }

        let sig = fourCharCode("STMP")

        for action in HotkeyAction.allCases {
            guard let combo = action.combo else { continue }   // nil = disabled
            var ref: EventHotKeyRef?
            registerHotKey(code: UInt32(combo.keyCode), mods: combo.carbonModifiers,
                           id: action.rawValue, sig: sig, ref: &ref)
            if let ref { hotKeyRefs[action] = ref }
        }
        lastHotkeyState = HotkeyAction.allCases.reduce(into: [HotkeyAction: HotkeyCombo?]()) {
            $0[$1] = $1.combo
        }
    }

    private func registerHotKey(code: UInt32, mods: UInt32, id: UInt32, sig: OSType, ref: inout EventHotKeyRef?) {
        let hotKeyID = EventHotKeyID(signature: sig, id: id)
        let status = RegisterEventHotKey(code, mods, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { ref = nil }
    }

    private func uninstallHotKey() {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()

        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
            self.hotKeyHandlerRef = nil
        }
    }

    private func handleHotKey(_ hotKeyID: EventHotKeyID) {
        // While the user is recording a new shortcut, Carbon hotkeys still fire
        // (they dispatch below the recorder's local NSEvent monitor). Ignore them
        // so pressing an existing combo doesn't trigger its action mid-record.
        guard !isRecordingHotkey else { return }
        guard let screen = preferredScreenForOpen() else { return }
        switch hotKeyID.id {
        case 1:
            // Toggle panel
            panel.toggleAnimated(on: screen)
        case 2:
            // Selection screenshot — show panel briefly then capture
            triggerCapture(mode: .selection, on: screen)
        case 3:
            // Fullscreen screenshot
            triggerCapture(mode: .screen, on: screen)
        case 4:
            // Window screenshot
            triggerCapture(mode: .window, on: screen)
        case 5:
            // Pick color — open panel then invoke pick color
            triggerPickColor(on: screen)
        case 7:
            // Scan — area selection, every barcode payload + recognized text
            // → clipboard + archive
            triggerScan(on: screen)
        case 8:
            // Pin last screenshot as a floating always-on-top window
            PinnedScreenshotController.shared.pinLastCapture(
                url: panel.screenshot.lastCaptureURL, on: screen)
        case 9:
            // Collect files — open the panel straight into the archive, pinned,
            // ready to receive file drops (Dropover-style collect flow)
            panel.openArchivePinned(on: screen)
        case 10:
            // Share the newest archive entry — archive up, share sheet on it
            panel.shareLastArchiveItem(on: screen)
        default:
            break
        }
    }

    private func triggerCapture(mode: CaptureMode, on screen: NSScreen) {
        // Инвариант: если needsSpaceRebind == true, panel.isVisible ненадёжен —
        // панель может быть привязана к другому Space. Не пытаемся её закрывать,
        // просто идём сразу в capture. Технически capture не сломается и без этой
        // проверки, но единообразие с остальными open/hide-путями важнее.
        if panel.isVisible && !panel.needsSpaceRebind {
            panel.hideAnimated(reason: .captureStart) { [weak self] in
                self?.panel.captureDirectly(mode: mode, on: screen)
            }
        } else {
            panel.captureDirectly(mode: mode, on: screen)
        }
    }

    private func triggerPickColor(on screen: NSScreen) {
        // При stale-состоянии panel.isVisible ненадёжен: панель может быть
        // привязана к другому Space. Без forceRebind pickColorDirectly() запустится
        // без обновления currentScreen и пипетка попадёт на не тот экран.
        if panel.isVisible && !panel.needsSpaceRebind {
            panel.pickColorDirectly()
        } else {
            panel.pickColorDirectly(on: screen)
        }
    }

    private func triggerScan(on screen: NSScreen) {
        // Тот же stale-инвариант, что и у triggerPickColor: при ненадёжной
        // Space-привязке передаём экран явно, чтобы overlay попал на активный.
        if panel.isVisible && !panel.needsSpaceRebind {
            panel.scan()
        } else {
            panel.scan(on: screen)
        }
    }

    private func installEventTap() {
        guard globalClickMonitor == nil && localClickMonitor == nil else { return }

        // Global: клики в других приложениях и системных областях (меню-бар,
        // мёртвая зона челки). Хендлер приходит на главном потоке; события
        // read-only — консьюмить их (как listenOnly-tap) и не требовалось.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .leftMouseDown
        ) { [weak self] _ in
            self?.handleGlobalLeftMouseDown()
        }

        // Local: клики по окнам самого Stampo (панель, настройки, редактор) —
        // глобальный монитор их не видит, а логика «клик по челке при открытой
        // панели» и «клик внутри панели» должна работать и для них.
        // Возвращаем событие как есть — ничего не перехватываем.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseDown
        ) { [weak self] event in
            self?.handleGlobalLeftMouseDown()
            return event
        }

        // NSEvent-мониторы мыши не требуют TCC-разрешений и не «умирают» от
        // смены сигнатуры — установка не может провалиться.
        NotchHoverController.isEventTapInstalled = true
        NotificationCenter.default.post(name: .notchClickStatusChanged, object: nil)
    }

    private func uninstallEventTap() {
        if let m = globalClickMonitor {
            NSEvent.removeMonitor(m)
            globalClickMonitor = nil
        }
        if let m = localClickMonitor {
            NSEvent.removeMonitor(m)
            localClickMonitor = nil
        }
        // Сбрасываем статус: мониторы сняты, Settings должен показать актуальное состояние.
        NotchHoverController.isEventTapInstalled = false
        NotificationCenter.default.post(name: .notchClickStatusChanged, object: nil)
    }

    private func handleGlobalLeftMouseDown() {
        let mouse = NSEvent.mouseLocation
        guard let screen = screenForPoint(mouse) else { return }

        // На экранах без челки триггер — зона в центре меню-бара (см. triggerRect).
        // Раньше здесь стоял `guard screen.notchGapWidth > 0`, из-за чего на
        // безчелочных дисплеях не работали ни открытие кликом, ни авто-закрытие
        // по клику снаружи. Теперь обе ветви ниже отрабатывают везде.
        let trigger = triggerRect(on: screen)
        guard !trigger.isNull else { return }

        let inTrigger = trigger.contains(mouse)
        let insidePanel = panel.isPointInsidePanel(mouse)
        DebugTrace.add(
            "globalMouseDown " +
            "inTrigger=\(inTrigger) insidePanel=\(insidePanel) " +
            "panelVisible=\(panel.isVisible) needsRebind=\(panel.needsSpaceRebind) " +
            "suppress=\(panel.suppressesGlobalAutoHide) " +
            "\(PanelTrace.mouseSummary(mouse))"
        )

        // После sleep/wake/Space-switch AppKit может считать панель isVisible==true,
        // хотя на текущем рабочем столе пользователь её не видит. Проверяем флаг
        // needsSpaceRebind, чтобы не уйти в ветку «закрыть невидимую панель».
        if panel.isVisible && !panel.needsSpaceRebind {
            if panel.suppressesGlobalAutoHide { return }
            // «Клик по триггеру = закрыть» применим только к физической челке, где
            // триггер — это мёртвая зона выреза без кнопок. На безчелочных экранах
            // зона-триггер в меню-баре перекрывает кнопки панели (notch-стиль
            // прижимает панель к меню-бару), поэтому закрытие — только по клику ВНЕ
            // панели; иначе нажатие, например, кнопки трея просто прятало бы панель.
            if screen.notchGapWidth > 0 && inTrigger {
                panel.hideAnimated(reason: .notchClick)
                return
            }
            if !insidePanel {
                panel.hideAnimated(reason: .outsideClick)
            }
            return
        }

        if inTrigger {
            panel.showAnimated(on: screen, forceRebind: panel.needsSpaceRebind)
        }
    }

    /// Reveals the panel on the most appropriate screen. Used when the user
    /// activates the app (e.g. clicking the icon in Launchpad/Dock) so the app
    /// visibly reacts instead of appearing dead. No-op if no screen is available.
    func revealPanel() {
        guard let screen = preferredScreenForOpen() else { return }
        panel.showAnimated(on: screen, forceRebind: panel.needsSpaceRebind)
    }

    /// Returns the screen best suited to present the panel on, or nil if no
    /// screen is currently available (headless / mid-reconfiguration). Callers
    /// must guard nil and skip the action rather than crashing on screens[0].
    private func preferredScreenForOpen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screenForPoint(mouse) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func screenForPoint(_ p: NSPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.main
    }

    /// Ширина зоны-триггера в центре меню-бара на экранах без физической челки.
    /// Примерно соответствует ширине выреза MacBook, чтобы цель клика ощущалась
    /// одинаково на разных дисплеях.
    private let noNotchTriggerWidth: CGFloat = 180

    private func triggerRect(on screen: NSScreen) -> CGRect {
        let sf = screen.frame
        let vf = screen.visibleFrame

        let menuBarHeight = max(0, sf.maxY - vf.maxY)
        guard menuBarHeight > 0 else { return .null }

        let notchWidth = screen.notchGapWidth
        let width: CGFloat
        if notchWidth > 0 {
            let horizontalHitInset: CGFloat = 12
            width = notchWidth + horizontalHitInset * 2
        } else {
            // Без челки: открываем/закрываем панель кликом по зоне в центре
            // меню-бара — там, где у MacBook был бы вырез.
            width = noNotchTriggerWidth
        }
        let x = sf.midX - width / 2
        let y = vf.maxY
        return CGRect(x: x, y: y, width: width, height: menuBarHeight)
    }
}

extension Notification.Name {
    /// Постится при изменении статуса мониторов клика по челке
    /// (установлены / сняты).
    static let notchClickStatusChanged = Notification.Name("Stampo.notchClickStatusChanged")

    /// Posted by ShortcutRecorderView with `object: Bool` (true = recording).
    /// NotchHoverController suppresses hotkey actions while recording.
    static let hotkeyRecordingChanged  = Notification.Name("Stampo.hotkeyRecordingChanged")

    /// Постится из NotchPanelController и ColorPickingCoordinator при смене
    /// состояния приложения. NotchHoverController передаёт это MascotStatusView.
    static let mascotStateChanged  = Notification.Name("Stampo.mascotStateChanged")

    /// Постится из ColorPickingCoordinator при каждом движении курсора.
    /// object = NSValue(point:) в экранных координатах.
    static let mascotCursorMoved   = Notification.Name("Stampo.mascotCursorMoved")
}


private func fourCharCode(_ string: String) -> OSType {
    assert(string.utf16.count == 4, "Hotkey signature must be 4 characters")
    guard string.utf16.count == 4 else { return 0 }
    return string.utf16.reduce(0) { partial, scalar in
        (partial << 8) + OSType(scalar)
    }
}
