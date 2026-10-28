import AppKit
import ApplicationServices
import XCTest

@MainActor
final class PanelE2ETests: E2ETestCase {
    func testOpenCloseCycles() throws {
        try app.launch()
        try recordWindowBaseline()
        let trigger = try XCTUnwrap(Input.notchTrigger, "Primary display has no menu-bar trigger")
        let closers = trigger.hasNotch ? ["escape", "button", "hotkey", "outside", "notch"]
            : ["escape", "button", "hotkey", "outside"]
        let pairs = ["hotkey", "notch"].flatMap { opener in closers.map { (opener, $0) } }
        for cycle in 0..<20 {
            let (opener, closer) = pairs[cycle % pairs.count]
            print("P1 starting cycle \(cycle + 1): \(opener) × \(closer), trigger=\(trigger.point)")
            try app.input.park()
            if opener == "hotkey" { try app.input.press("⌃⌥⌘N") }
            else { try app.input.click(at: trigger.point) }
            print("P1 pointer after opening input: \(Input.quartzPoint(fromAppKit: NSEvent.mouseLocation)), HID=\(String(describing: CGEvent(source: nil)?.location))")
            let frame = try settledPanel()
            XCTAssertEqual(frame.minY, 0, accuracy: 1, "Panel window is displaced from the top edge: \(frame)")
            let mode = try required(.panelModeMenu)
            let modeFrame = try XCTUnwrap(mode.frame, "Mode button has no frame")
            let offset = modeFrame.minY - frame.minY
            print("P1 cycle \(cycle + 1): \(opener) × \(closer), frame=\(frame), content offset=\(offset) pt")
            // Measured on the healthy notched primary display. Check content
            // placement separately because the window can still start at y=0.
            XCTAssertEqual(offset, 4, accuracy: 2,
                           "panel content top offset \(offset) pt, expected 4 (±2)")
            try artifacts.step("cycle-\(cycle + 1)-open")
            switch closer {
            case "escape": try app.input.press("ESC")
            case "button": try tapLive(.panelClose)
            case "hotkey": try app.input.press("⌃⌥⌘N")
            case "notch": try app.input.click(at: trigger.point)
            default:
                try app.input.park()
                let display = CGDisplayBounds(CGMainDisplayID())
                try app.input.click(at: CGPoint(x: display.minX + 20, y: display.maxY - 40))
            }
            try expectPanelClosed()
            expectWindowSetUnchanged()
            try artifacts.step("cycle-\(cycle + 1)-closed")
        }
    }

    func testPanelMenus() throws {
        try app.launch(fixture: true)
        try recordWindowBaseline()
        try openPanel()
        // CaptureMode.localizedTitle/accessibilityValue and CaptureDelay.allCases
        // in NotchPanelView.swift; Scrolling also announces its direction.
        let menus: [(E2EApp.Control, [(String, String)])] = [
            (.panelModeMenu, [("Selection", "Selection"), ("Window", "Window"),
                              ("Scrolling", "Scrolling, down"), ("Entire Screen", "Entire Screen")]),
            (.panelDelayMenu, [("No Delay", "No Delay"), ("3 Seconds", "3 Seconds"),
                               ("5 Seconds", "5 Seconds"), ("10 Seconds", "10 Seconds")])
        ]
        for (control, choices) in menus {
            for (title, expected) in choices {
                // Pick a different value once before comparing the same glyph.
                // The initial Selection/No Delay comparisons start untouched,
                // so a stuck first interaction cannot become its own baseline.
                if try required(control).value != expected {
                    try select(title, in: control)
                    try expectValue(control, expected, message: "Menu did not select \(title)")
                }
                let before = try stableButton(control, label: "\(title)-before")
                try select(title, in: control)
                try expectValue(control, expected, message: "Menu did not select \(title)")
                let after = try stableButton(control, label: "\(title)-released")
                expectReleased(before, after, message: "\(control.rawValue) remained highlighted after \(title)")
                try closePanel()
                try openPanel()
                try expectValue(.panelModeMenu, "Selection", message: "Reopen did not restore the E2E default mode")
                try expectValue(.panelDelayMenu, "No Delay", message: "Reopen did not restore the E2E default delay")
            }
        }
        let before = try stableButton(.panelMoreMenu, label: "more-before")
        let openWindows = try captureWindowBaseline(name: "before-more-settings")
        try select("Settings", in: .panelMoreMenu)
        try closeSettingsWindow()
        // The phase snapshot keeps the panel on screen. It does not replace
        // teardown's original closed-panel baseline or exempt any window ids.
        expectWindowSetUnchanged(baseline: openWindows)
        let immediate = try stableButton(.panelMoreMenu, label: "more-immediately-after-settings")
        expectReleased(before, immediate, message: "More button remained highlighted immediately after Settings")
        try normalizePanelAfterSettings()
        try openPanel()
        let after = try stableButton(.panelMoreMenu, label: "more-after-settings")
        expectReleased(before, after, message: "More button remained highlighted after Settings")
        try closePanel()
    }

    func testMoreMenuClosesOnEsc() throws {
        try app.launch(fixture: true)
        try recordWindowBaseline()
        try openPanel()
        try openMenu(.panelMoreMenu)
        try app.input.park()
        try app.input.press("ESC")
        XCTAssertTrue(waitUntil(timeout: 3) { self.visibleMenu == nil }, "More menu did not close after Esc")
        try artifacts.step("menu-closed-by-esc")
        try closePanel()
    }

    func testTabFollowsPointer() throws {
        try app.launch(fixture: true)
        _ = try required(.fixtureKeys)
        try recordWindowBaseline()
        try openPanel()
        try select("Scrolling", in: .panelModeMenu)
        try expectValue(.panelModeMenu, "Scrolling, down", message: "Scrolling was not selected")
        let counter = try required(.fixtureKeys)
        let initialCount = try XCTUnwrap(Int(counter.value), "Fixture key counter is not numeric: \(counter.value)")
        let mode = try required(.panelModeMenu)
        let modeFrame = try XCTUnwrap(mode.frame, "Mode button has no frame")
        try app.input.move(to: CGPoint(x: modeFrame.midX, y: modeFrame.midY))
        // The controller updates transient hotkeys from hover on the next
        // event-loop turn; observe the stationary pointer before posting Tab.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        try app.input.press("TAB")
        try expectValue(.panelModeMenu, "Scrolling, right", message: "Tab over the drawn panel did not change direction")
        XCTAssertEqual(try required(.fixtureKeys).value, String(initialCount), "Panel Tab leaked to the fixture")
        try artifacts.step("tab-over-drawn-panel")

        let panelFrame = try settledPanel()
        let controls = try [E2EApp.Control.panelClose, .panelModeMenu, .panelDelayMenu, .panelMoreMenu]
            .map { try XCTUnwrap(required($0).frame, "Panel control has no frame") }
        let below = CGPoint(x: modeFrame.midX, y: (controls.map(\.maxY).max() ?? 0) + 12)
        XCTAssertTrue(panelFrame.contains(below), "Tab target must be inside the panel window: \(below), \(panelFrame)")
        try app.input.move(to: below)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNotNil(app.liveElement(.panel), "Panel closed before the empty-window Tab")
        try app.input.press("TAB")
        let received = waitUntil(timeout: 3) { self.app.liveElement(.fixtureKeys)?.value == String(initialCount + 1) }
        let actual = try required(.fixtureKeys).value
        XCTAssertTrue(received, "Tab did not reach the fixture: counter \(actual), expected \(initialCount + 1)")
        XCTAssertEqual(try required(.panelModeMenu).value, "Scrolling, right", "Tab outside the drawn panel changed direction")
        print("P4 below strip: point=\(below), window=\(panelFrame), fixture counter=\(actual)")
        try artifacts.step("tab-below-drawn-panel")
        try closePanel()
    }

    func testStatusMenuSettings() throws {
        // A key fixture window establishes AppKit's activation/menu-bar cache
        // before the baseline, independently of the Settings action under test.
        try app.launch(fixture: true)
        try recordWindowBaseline()
        try openStatusMenu()
        try app.tap(.statusSettings)
        let settings = app.application.windows["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 3), "settings window did not open")
        try artifacts.text(app.application.debugDescription, name: "settings-tree.txt")
        try artifacts.step("settings-open")
        for tab in ["general", "capture", "archive", "hotkeys", "about"] {
            let identifier = "stampo.settings.tab.\(tab)"
            XCTAssertTrue(app.application.descendants(matching: .any)[identifier].firstMatch.exists,
                          "Settings tab is absent from Accessibility: \(identifier); see settings-tree.txt")
        }
        try app.input.press("⌘W")
        try app.input.park()
        XCTAssertTrue(waitUntil(timeout: 3) { !settings.exists }, "Settings window remained after ⌘W")
        expectWindowSetUnchanged()
        try artifacts.step("settings-closed")
    }

    func testStatusMenuQuit() throws {
        // A key fixture window establishes AppKit's activation/menu-bar cache
        // before the baseline, independently of the Settings action under test.
        try app.launch(fixture: true)
        try recordWindowBaseline()
        try openStatusMenu()
        guard let pid = app.processID else { throw E2EFailure("Missing process before Quit") }
        app.expectQuit()
        try app.tap(.statusQuit)
        XCTAssertTrue(waitUntil(timeout: 5) { NSRunningApplication(processIdentifier: pid) == nil },
                      "process still alive 5 s after Quit")
        try artifacts.step("quit")
    }

    private func required(_ control: E2EApp.Control, file: StaticString = #filePath, line: UInt = #line) throws -> AccessibilityNode {
        let exists = waitUntil(timeout: 3) { self.app.liveElement(control) != nil }
        XCTAssertTrue(exists, "Missing \(control.rawValue) before reading its value/frame", file: file, line: line)
        return try XCTUnwrap(app.liveElement(control), "Missing \(control.rawValue)", file: file, line: line)
    }

    private func tapLive(_ control: E2EApp.Control) throws {
        let target = try required(control)
        let frame = try XCTUnwrap(target.frame, "Missing hit target for \(control.rawValue)")
        XCTAssertFalse(frame.isEmpty, "Empty hit target for \(control.rawValue)")
        try app.input.click(at: CGPoint(x: frame.midX, y: frame.midY))
    }

    @discardableResult
    private func settledPanel() throws -> CGRect {
        _ = try required(.panel)
        let deadline = Date().addingTimeInterval(3)
        var previous: CGRect?
        var stable = 0
        repeat {
            if let frame = app.liveElement(.panel)?.frame, !frame.isEmpty {
                stable = frame == previous ? stable + 1 : 0
                if stable >= 2 { return frame }
                previous = frame
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        XCTFail("Panel frame did not settle in two consecutive 100 ms probes within 3 s")
        throw E2EFailure("Unsettled panel: \(String(describing: previous))")
    }

    private func openPanel() throws {
        try app.input.park()
        try app.input.press("⌃⌥⌘N")
        try settledPanel()
    }

    private func expectPanelClosed() throws {
        XCTAssertTrue(waitUntil(timeout: 3) { self.app.liveElement(.panel) == nil }, "Panel did not disappear in 3 s")
        try app.input.park()
    }

    private func closePanel() throws {
        try tapLive(.panelClose)
        try expectPanelClosed()
        expectWindowSetUnchanged()
    }

    private var visibleMenu: AccessibilityNode? {
        app.accessibilityRoot?.first { $0.role == kAXMenuRole && !($0.frame?.isEmpty ?? true) }
    }

    private func openMenu(_ control: E2EApp.Control) throws {
        try app.input.park()
        try tapLive(control)
        XCTAssertTrue(waitUntil(timeout: 3) { self.visibleMenu != nil }, "\(control.rawValue) did not open a menu")
    }

    private func select(_ title: String, in control: E2EApp.Control) throws {
        try app.input.park()
        let frame = try XCTUnwrap(required(control).frame, "Missing menu-button hit target")
        let start = CGPoint(x: frame.midX, y: frame.midY)
        var release = start
        var held = true
        try app.input.holdMouse(at: start)
        defer { if held { try? app.input.releaseMouse(at: release) } }
        XCTAssertTrue(waitUntil(timeout: 3) { self.visibleMenu != nil }, "\(control.rawValue) did not open while pressed")
        let item = try visibleMenuItemFrame(title)
        release = CGPoint(x: item.midX, y: item.midY)
        // daf3bad/fabf326 lost the release and pointer exit inside NSMenu's
        // tracking loop. Keep the button down until the pointer leaves it
        // for the item, instead of releasing on the button before choosing.
        try app.input.dragHeldMouse(from: start, to: release)
        try app.input.releaseMouse(at: release)
        held = false
        XCTAssertTrue(waitUntil(timeout: 3) { self.visibleMenu == nil }, "Menu did not close in 3 s after \(title)")
        try app.input.park()
    }

    private func visibleMenuItemFrame(_ title: String) throws -> CGRect {
        let menu = try XCTUnwrap(visibleMenu, "Menu disappeared before selecting \(title)")
        let item = try XCTUnwrap(menu.first { $0.role == kAXMenuItemRole && $0.title == title }, "Missing menu item \(title)")
        let frame = try XCTUnwrap(item.frame, "Menu item \(title) has no frame")
        XCTAssertFalse(frame.isEmpty, "Menu item \(title) is hidden")
        return frame
    }

    private func selectVisibleMenuItem(_ title: String) throws {
        try app.input.park()
        let frame = try visibleMenuItemFrame(title)
        try app.input.click(at: CGPoint(x: frame.midX, y: frame.midY))
        XCTAssertTrue(waitUntil(timeout: 3) { self.visibleMenu == nil }, "Menu did not close in 3 s after \(title)")
        try app.input.park()
    }

    private func closeSettingsWindow() throws {
        let settings = app.application.windows["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 3), "settings window did not open")
        let general = app.application.descendants(matching: .any)["stampo.settings.tab.general"].firstMatch
        XCTAssertTrue(general.exists, "Settings did not expose its General tab")
        try artifacts.step("settings-from-more")
        try app.input.press("⌘W")
        XCTAssertTrue(waitUntil(timeout: 3) { !settings.exists }, "Settings window remained after ⌘W")
        try app.input.park()
    }

    private func normalizePanelAfterSettings() throws {
        // Current settingsTapped opens Settings without hiding the panel.
        // Normalize through the real hotkey, without crossing the More button
        // and resetting the hover/press state whose release is being tested.
        if app.liveElement(.panel) != nil {
            print("Settings left the panel visible; closing with HID hotkey before the window baseline")
            try app.input.press("⌃⌥⌘N")
        }
        try expectPanelClosed()
        expectWindowSetUnchanged()
    }

    private func expectValue(_ control: E2EApp.Control, _ expected: String, message: String) throws {
        _ = try required(control)
        let matches = waitUntil(timeout: 3) { self.app.liveElement(control)?.value == expected }
        let actual = try required(control).value
        XCTAssertTrue(matches, "\(message): value \(actual), expected \(expected)")
    }

    private struct ButtonSnapshot {
        let frame: CGRect
        let pixels: [UInt8]
    }

    private func stableButton(_ control: E2EApp.Control, label: String) throws -> ButtonSnapshot {
        try app.input.park()
        _ = try required(control)
        let display = CGDisplayBounds(CGMainDisplayID())
        let deadline = Date().addingTimeInterval(3)
        var previous: [UInt8]?
        var previousFrame: CGRect?
        var stable = 0
        repeat {
            // Delay choices resize the native button after changing its value.
            // A fixed crop can appear stable while its real bounds still move.
            let frame = try XCTUnwrap(required(control).frame, "Button has no frame before screenshot")
            XCTAssertFalse(frame.isEmpty, "Button region is empty")
            XCTAssertTrue(display.contains(frame), "Button comparison is limited to the primary display")
            let png = try artifacts.step(label)
            let bitmap = try Files.Bitmap(png: png)
            let scale = CGFloat(bitmap.width) / display.width
            let rect = CGRect(x: (frame.minX - display.minX) * scale, y: (frame.minY - display.minY) * scale,
                              width: frame.width * scale, height: frame.height * scale).integral
            var pixels: [UInt8] = []
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) { pixels += try bitmap.rgba(x: x, y: y) }
            }
            if let previous, frame == previousFrame, pixels.count == previous.count,
               zip(pixels, previous).allSatisfy({ abs(Int($0) - Int($1)) <= 2 }) { stable += 1 }
            else { stable = 0 }
            if stable >= 2 { return ButtonSnapshot(frame: frame, pixels: pixels) }
            previous = pixels
            previousFrame = frame
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        XCTFail("\(control.rawValue) pixels did not settle within 3 s")
        throw E2EFailure("Unsettled button pixels")
    }

    private func expectReleased(_ before: ButtonSnapshot, _ after: ButtonSnapshot, message: String) {
        XCTAssertEqual(before.frame, after.frame, "\(message): button frame changed")
        XCTAssertEqual(before.pixels.count, after.pixels.count, "\(message): pixel count changed")
        let differences = zip(before.pixels, after.pixels).map { abs(Int($0) - Int($1)) }
        let maximum = differences.max() ?? 0
        XCTAssertLessThanOrEqual(maximum, 2, "\(message): maximum channel difference \(maximum), tolerance ±2")
    }

    private var statusMenuIsVisible: Bool {
        let settings = app.element(.statusSettings)
        let quit = app.element(.statusQuit)
        return settings.exists && quit.exists && !settings.frame.isEmpty && !quit.frame.isEmpty
    }

    private func openStatusMenu() throws {
        try app.input.park()
        try artifacts.text(app.application.debugDescription, name: "before-status-menu-tree.txt")
        print("Status item frame: \(app.element(.statusItem).frame)")
        try app.tap(.statusItem)
        var opened = waitUntil(timeout: 1) { self.statusMenuIsVisible }
        try artifacts.step("status-after-left-click")
        print("Status menu HID left click: \(opened ? "opened" : "did not open")")
        if !opened {
            let frame = app.element(.statusItem).frame
            try app.input.rightClick(at: CGPoint(x: frame.midX, y: frame.midY))
            opened = waitUntil(timeout: 1) { self.statusMenuIsVisible }
            try artifacts.step("status-after-right-click")
            print("Status menu HID right click: \(opened ? "opened" : "did not open")")
        }
        if !opened {
            guard let status = app.liveElement(.statusItem) else { throw E2EFailure("Status item is absent before AXPress") }
            // NSStatusItem may keep AXPress pending in its menu tracking loop.
            // Judge opening by the visible menu, and retain the AX result too.
            do { try status.press() }
            catch { print("Status AXPress result: \(error)") }
            opened = waitUntil(timeout: 1) { self.statusMenuIsVisible }
            try artifacts.step("status-after-ax-press")
            print("Status menu Accessibility press: \(opened ? "opened" : "did not open")")
        }
        try artifacts.text(app.application.debugDescription, name: "status-menu-tree.txt")
        XCTAssertTrue(opened, "Status menu did not open by HID left/right click or Accessibility press")
        XCTAssertTrue(app.element(.statusSettings).exists, "Status menu is missing Settings")
        XCTAssertTrue(app.element(.statusQuit).exists, "Status menu is missing Quit")
        try artifacts.step("status-menu")
    }
}
