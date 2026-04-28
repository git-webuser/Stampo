import AppKit
import CoreGraphics
import Carbon
import OSLog

final class NotchHoverController: NSObject {
    private let panel: NotchPanelController

    /// True если CGEvent tap для области челки установлен успешно.
    /// Читается из GeneralSettingsView для отображения статуса разрешений.
    static private(set) var isEventTapInstalled: Bool = false

    private var statusItem: NSStatusItem?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?

    // Registered hotkey refs for capture actions
    private var hotKeyRefSelection: EventHotKeyRef?
    private var hotKeyRefFullscreen: EventHotKeyRef?
    private var hotKeyRefWindow: EventHotKeyRef?
    private var hotKeyRefColor: EventHotKeyRef?

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
            selector: #selector(onRetryEventTapInstall),
            name: .retryEventTapInstall,
            object: nil
        )
    }

    func stop() {
        NotificationCenter.default.removeObserver(self, name: .settingsWindowDidClose, object: nil)
        NotificationCenter.default.removeObserver(self, name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: .retryEventTapInstall, object: nil)
        uninstallEventTap()
        uninstallHotKey()
        uninstallStatusItem()
    }

    @objc private func onSettingsDidClose() {
        reinstallHotKeysIfNeeded()
    }

    @objc private func onRetryEventTapInstall() {
        uninstallEventTap()
        installEventTap()
    }

    @objc private func onUserDefaultsChanged() {
        reinstallHotKeysIfNeeded()
        updateStatusItemMenuTitles()
    }

    private var lastHotkeyEnabledState: [UInt32: Bool] = [
        1: true, 2: true, 3: true, 4: true, 5: true
    ]

    private func reinstallHotKeysIfNeeded() {
        let current: [UInt32: Bool] = [
            1: AppSettings.hotkeyPanelEnabled,
            2: AppSettings.hotkeySelectionEnabled,
            3: AppSettings.hotkeyFullscreenEnabled,
            4: AppSettings.hotkeyWindowEnabled,
            5: AppSettings.hotkeyColorEnabled
        ]
        guard current != lastHotkeyEnabledState else { return }
        uninstallHotKey()
        installHotKey()
    }

    private var statusItemSettingsItem: NSMenuItem?
    private var statusItemQuitItem: NSMenuItem?

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Stampo")
        button.imagePosition = .imageOnly

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

        let mods = UInt32(controlKey | optionKey | cmdKey)
        let sig = fourCharCode("NTSH")

        // id=1  Ctrl+Opt+Cmd+N  — toggle panel
        if AppSettings.hotkeyPanelEnabled {
            registerHotKey(code: UInt32(kVK_ANSI_N), mods: mods, id: 1, sig: sig, ref: &hotKeyRef)
        }
        // id=2  Ctrl+Opt+Cmd+R  — selection screenshot
        if AppSettings.hotkeySelectionEnabled {
            registerHotKey(code: UInt32(kVK_ANSI_R), mods: mods, id: 2, sig: sig, ref: &hotKeyRefSelection)
        }
        // id=3  Ctrl+Opt+Cmd+B  — fullscreen screenshot
        if AppSettings.hotkeyFullscreenEnabled {
            registerHotKey(code: UInt32(kVK_ANSI_B), mods: mods, id: 3, sig: sig, ref: &hotKeyRefFullscreen)
        }
        // id=4  Ctrl+Opt+Cmd+G  — window screenshot
        if AppSettings.hotkeyWindowEnabled {
            registerHotKey(code: UInt32(kVK_ANSI_G), mods: mods, id: 4, sig: sig, ref: &hotKeyRefWindow)
        }
        // id=5  Ctrl+Opt+Cmd+C  — pick color
        if AppSettings.hotkeyColorEnabled {
            registerHotKey(code: UInt32(kVK_ANSI_C), mods: mods, id: 5, sig: sig, ref: &hotKeyRefColor)
        }
        lastHotkeyEnabledState = [
            1: AppSettings.hotkeyPanelEnabled,
            2: AppSettings.hotkeySelectionEnabled,
            3: AppSettings.hotkeyFullscreenEnabled,
            4: AppSettings.hotkeyWindowEnabled,
            5: AppSettings.hotkeyColorEnabled
        ]
    }

    private func registerHotKey(code: UInt32, mods: UInt32, id: UInt32, sig: OSType, ref: inout EventHotKeyRef?) {
        let hotKeyID = EventHotKeyID(signature: sig, id: id)
        let status = RegisterEventHotKey(code, mods, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { ref = nil }
    }

    private func uninstallHotKey() {
        for ref in [hotKeyRef, hotKeyRefSelection, hotKeyRefFullscreen, hotKeyRefWindow, hotKeyRefColor].compactMap({ $0 }) {
            UnregisterEventHotKey(ref)
        }
        hotKeyRef = nil
        hotKeyRefSelection = nil
        hotKeyRefFullscreen = nil
        hotKeyRefWindow = nil
        hotKeyRefColor = nil

        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
            self.hotKeyHandlerRef = nil
        }
    }

    private func handleHotKey(_ hotKeyID: EventHotKeyID) {
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
            panel.hideAnimated { [weak self] in
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

    private func installEventTap() {
        let mask = (1 << CGEventType.leftMouseDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let controller = Unmanaged<NotchHoverController>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = controller.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            guard type == .leftMouseDown else {
                return Unmanaged.passUnretained(event)
            }

            DispatchQueue.main.async {
                controller.handleGlobalLeftMouseDown()
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.input.error("CGEvent.tapCreate returned nil — Input Monitoring permission likely missing")
            NotchHoverController.isEventTapInstalled = false
            NotificationCenter.default.post(name: .notchClickStatusChanged, object: nil)
            // Alert показываем только один раз за «жизнь» разрешения: при первой
            // ошибке. Повторные запуски без разрешения — тихо, статус виден в Settings.
            // Флаг сбрасывается при успешной установке tap, поэтому если пользователь
            // сначала выдаст разрешение, а потом отзовёт — alert покажется снова.
            let alreadyShown = UserDefaults.standard.bool(forKey: AppSettings.Keys.notchClickAlertShown)
            if !alreadyShown {
                UserDefaults.standard.set(true, forKey: AppSettings.Keys.notchClickAlertShown)
                UserFacingError.present(.notchClickUnavailable)
            }
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            Log.input.error("CFMachPortCreateRunLoopSource returned nil for event tap")
            NotchHoverController.isEventTapInstalled = false
            NotificationCenter.default.post(name: .notchClickStatusChanged, object: nil)
            return
        }

        self.eventTap = tap
        self.eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NotchHoverController.isEventTapInstalled = true
        NotificationCenter.default.post(name: .notchClickStatusChanged, object: nil)
        // Tap установлен — сбрасываем флаг чтобы при следующем отзыве разрешения
        // пользователь снова увидел объясняющий alert.
        UserDefaults.standard.removeObject(forKey: AppSettings.Keys.notchClickAlertShown)
    }

    private func uninstallEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.eventTapSource = nil
        }
        self.eventTap = nil
        // Сбрасываем статус: tap снят, Settings должен показать актуальное состояние.
        NotchHoverController.isEventTapInstalled = false
        NotificationCenter.default.post(name: .notchClickStatusChanged, object: nil)
    }

    private func handleGlobalLeftMouseDown() {
        let mouse = NSEvent.mouseLocation
        guard let screen = screenForPoint(mouse) else { return }
        guard screen.notchGapWidth > 0 else { return }

        let trigger = triggerRect(on: screen)
        guard !trigger.isNull else { return }

        // После sleep/wake/Space-switch AppKit может считать панель isVisible==true,
        // хотя на текущем рабочем столе пользователь её не видит. Проверяем флаг
        // needsSpaceRebind, чтобы не уйти в ветку «закрыть невидимую панель».
        if panel.isVisible && !panel.needsSpaceRebind {
            if panel.suppressesGlobalAutoHide { return }
            if trigger.contains(mouse) {
                panel.hideAnimated()
                return
            }
            if !panel.isPointInsidePanel(mouse) {
                panel.hideAnimated()
            }
            return
        }

        if trigger.contains(mouse) {
            panel.showAnimated(on: screen, forceRebind: panel.needsSpaceRebind)
        }
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

    private func triggerRect(on screen: NSScreen) -> CGRect {
        let sf = screen.frame
        let vf = screen.visibleFrame
        let notchWidth = screen.notchGapWidth
        guard notchWidth > 0 else { return .null }

        let menuBarHeight = max(0, sf.maxY - vf.maxY)
        guard menuBarHeight > 0 else { return .null }

        let horizontalHitInset: CGFloat = 12
        let width = notchWidth + horizontalHitInset * 2
        let x = sf.midX - width / 2
        let y = vf.maxY
        return CGRect(x: x, y: y, width: width, height: menuBarHeight)
    }
}

extension Notification.Name {
    /// Постится при изменении статуса CGEvent tap (установлен / не установлен).
    /// GeneralSettingsView подписывается через `.onReceive` для обновления индикатора.
    static let notchClickStatusChanged = Notification.Name("Stampo.notchClickStatusChanged")

    /// Постится из GeneralSettingsView при нажатии кнопки Retry.
    /// NotchHoverController реагирует переустановкой event tap.
    static let retryEventTapInstall    = Notification.Name("Stampo.retryEventTapInstall")
}

private func fourCharCode(_ string: String) -> OSType {
    assert(string.utf16.count == 4, "Hotkey signature must be 4 characters")
    guard string.utf16.count == 4 else { return 0 }
    return string.utf16.reduce(0) { partial, scalar in
        (partial << 8) + OSType(scalar)
    }
}
