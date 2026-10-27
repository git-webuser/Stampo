#if DEBUG
import AppKit
import SwiftUI

/// E2E state belongs to the separately signed bundle. The normal Debug launch
/// takes none of these paths, and Release compiles out this entire file.
enum E2EHooks {
    nonisolated static let isEnabled = ProcessInfo.processInfo.arguments.contains("-StampoE2E")
    private static var fixture: NSWindow?

    static func prepare() {
        guard isEnabled else { return }
        precondition(Bundle.main.bundleIdentifier == "com.hex000.Stampo.e2e",
                     "E2E requires the isolated com.hex000.Stampo.e2e copy")
        let defaults = UserDefaults.standard
        defaults.removePersistentDomain(forName: "com.hex000.Stampo.e2e")
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        // Reset only our identity. Volatile values keep hotkeys and the save
        // path deterministic without borrowing any preferences from the dev app.
        arguments[AppSettings.Keys.copyToClipboard] = false
        arguments[AppSettings.Keys.playSound] = false
        arguments[AppSettings.Keys.persistTray] = false
        arguments[AppSettings.Keys.defaultCaptureMode] = "selection"
        arguments[AppSettings.Keys.defaultTimerDelay] = 0
        for key in ["hotkeysMigratedToCombos", "hotkeysMergedScanHotkey", "hotkeysReshuffledPins"] {
            arguments[key] = true
        }
        for action in HotkeyAction.allCases {
            let combo = action.defaultCombo
            arguments["hotkey.combo.\(action.rawValue)"] = try? JSONSerialization.data(withJSONObject: [
                "combo": ["keyCode": Int(combo.keyCode), "carbonModifiers": Int(combo.carbonModifiers)]
            ])
        }
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    static func start() {
        guard isEnabled else { return }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-StampoE2EFixture") { showFixture() }
        if let index = arguments.firstIndex(of: "-StampoE2EOpenEditor"),
           arguments.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: arguments[index + 1])
            DispatchQueue.main.async { EditorWindowController.open(url: url) }
        }
    }

    private static func showFixture() {
        let bounds = NSRect(x: 0, y: 0, width: 300, height: 200)
        let window = NSWindow(contentRect: bounds, styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Stampo E2E Fixture"
        window.setAccessibilityIdentifier("stampo.e2e.fixture")
        window.isReleasedWhenClosed = false
        window.contentView = FixtureView(frame: bounds)
        if let screen = NSScreen.screens.first {
            window.setFrameOrigin(NSPoint(x: screen.frame.midX - window.frame.width / 2,
                                          y: screen.frame.midY - window.frame.height / 2))
        }
        fixture = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private final class FixtureView: NSView {
        override var isOpaque: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height).fill()
            NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).setFill()
            NSRect(x: bounds.width / 2, y: 0, width: bounds.width / 2, height: bounds.height).fill()
        }
    }
}
/// The canvas has no accessible descendants in normal launches. E2E needs
/// its actual bounds as a hit target without adding labels or values.
struct E2ECanvasAccessibility: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if E2EHooks.isEnabled {
            content.accessibilityElement(children: .contain)
                .accessibilityIdentifier("stampo.editor.canvas")
        } else {
            content
        }
    }
}
#endif
