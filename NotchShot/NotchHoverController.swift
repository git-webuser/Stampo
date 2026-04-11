import AppKit
import CoreGraphics
import Carbon

final class NotchHoverController: NSObject {
    private let panel: NotchPanelController

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
    }

    func stop() {
        NotificationCenter.default.removeObserver(self, name: .settingsWindowDidClose, object: nil)
        NotificationCenter.default.removeObserver(self, name: UserDefaults.didChangeNotification, object: nil)
        uninstallEventTap()
        uninstallHotKey()
        uninstallStatusItem()
    }

    @objc private func onSettingsDidClose() {
        reinstallHotKeysIfNeeded()
    }

    @objc private func onUserDefaultsChanged() {
        reinstallHotKeysIfNeeded()
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

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "NotchShot")
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp])
    }

    private func uninstallStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @objc
    private func statusItemClicked() {
        let screen = preferredScreenForOpen()
        panel.toggleAnimated(on: screen)
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
        let screen = preferredScreenForOpen()
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
        // If panel is visible, hide it first, then capture
        if panel.isVisible {
            panel.hideAnimated { [weak self] in
                self?.panel.captureDirectly(mode: mode, on: screen)
            }
        } else {
            panel.captureDirectly(mode: mode, on: screen)
        }
    }

    private func triggerPickColor(on screen: NSScreen) {
        if panel.isVisible {
            panel.pickColorDirectly()
        } else {
            panel.showAnimated(on: screen)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.panel.pickColorDirectly()
            }
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
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return
        }

        self.eventTap = tap
        self.eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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
    }

    private func handleGlobalLeftMouseDown() {
        let mouse = NSEvent.mouseLocation
        guard let screen = screenForPoint(mouse) else { return }
        guard screen.notchGapWidth > 0 else { return }

        let trigger = triggerRect(on: screen)
        guard !trigger.isNull else { return }

        if panel.isVisible {
            if panel.suppressesGlobalAutoHide {
                return
            }
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
            panel.showAnimated(on: screen)
        }
    }

    private func preferredScreenForOpen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        guard let screen = screenForPoint(mouse) ?? NSScreen.main ?? NSScreen.screens.first else {
            fatalError("No screens available")
        }
        return screen
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

private func fourCharCode(_ string: String) -> OSType {
    assert(string.utf16.count == 4, "Hotkey signature must be 4 characters")
    guard string.utf16.count == 4 else { return 0 }
    return string.utf16.reduce(0) { partial, scalar in
        (partial << 8) + OSType(scalar)
    }
}
