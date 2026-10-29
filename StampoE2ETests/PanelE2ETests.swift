import AppKit
import ApplicationServices
import XCTest

@MainActor
final class PanelE2ETests: E2ETestCase {
    func testStatusItemIsDrawn() throws {
        try app.launch()
        try recordWindowBaseline(primePanelCache: false)
        _ = try verifiedStatusItemFrame()
        expectWindowSetUnchanged()
    }

    func testAXQueryRejectsTerminatedProcess() throws {
        try app.launch()
        try recordWindowBaseline(primePanelCache: false)
        let pid = try XCTUnwrap(app.processID, "Missing AX probe PID")
        try app.terminateForAccessibilityProbe()
        XCTAssertTrue(waitUntil(timeout: 3) { NSRunningApplication(processIdentifier: pid) == nil },
                      "AX probe process did not terminate")
        XCTAssertThrowsError(try app.liveElement(.statusItem)) { error in
            let message = String(describing: error)
            print("AX terminated-process probe: \(message)")
            XCTAssertTrue(message.contains("AX"), "Expected an AX read error, received \(message)")
        }
    }

    func testOpenCloseCycles() throws {
        let trigger = try XCTUnwrap(Input.notchTrigger, "Primary display has no menu-bar trigger: \(Input.primaryDisplayDescription)")
        XCTAssertTrue(trigger.hasNotch,
                      "P1 top-edge constants were measured only on a notched primary display; primary display is \(Input.primaryDisplayDescription)")
        try app.launch()
        try recordWindowBaseline()
        let closers = ["escape", "button", "hotkey", "notch"]
        let pairs = ["hotkey", "notch"].flatMap { opener in closers.map { (opener, $0) } }
        for cycle in 0..<20 {
            let (opener, closer) = pairs[cycle % pairs.count]
            print("P1 starting cycle \(cycle + 1): \(opener) × \(closer), trigger=\(trigger.point), frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
            try app.input.park()
            if opener == "hotkey" { try app.input.press("⌃⌥⌘N") }
            else { try app.input.click(at: trigger.point) }
            print("P1 pointer after opening input: \(Input.quartzPoint(fromAppKit: NSEvent.mouseLocation)), HID=\(String(describing: CGEvent(source: nil)?.location))")
            let previous = cycle == 0 ? ("baseline hotkey", "button") : pairs[(cycle - 1) % pairs.count]
            let context = "Panel did not appear after \(opener) (cycle \(cycle + 1); previous close \(previous.0) × \(previous.1))"
            let frame = try settledPanel(context: context)
            XCTAssertEqual(frame.minY, 0, accuracy: 1, "Panel window is displaced from the top edge: \(frame)")
            let mode = try required(.panelModeMenu)
            let modeFrame = try XCTUnwrap(mode.frame, "Mode button has no frame")
            let offset = modeFrame.minY - frame.minY
            print("P1 cycle \(cycle + 1): \(opener) × \(closer), frame=\(frame), content offset=\(offset) pt")
            // Measured 5 pt on the healthy notched primary display. Check content
            // placement separately because the window can still start at y=0.
            XCTAssertEqual(offset, 5, accuracy: 2,
                           "panel content top offset \(offset) pt, expected 5 (±2)")
            try artifacts.step("cycle-\(cycle + 1)-open")
            switch closer {
            case "escape": try app.input.press("ESC")
            case "button": try tapLive(.panelClose)
            case "hotkey": try app.input.press("⌃⌥⌘N")
            case "notch": try app.input.click(at: trigger.point)
            default: XCTFail("Unknown P1 closer: \(closer)")
            }
            try expectPanelClosed()
            expectWindowSetUnchanged()
            try artifacts.step("cycle-\(cycle + 1)-closed")
        }
    }

    func testOutsideClickCloses() throws {
        try app.launch(fixture: true)
        try recordWindowBaseline()
        let trigger = try XCTUnwrap(Input.notchTrigger, "Primary display has no menu-bar trigger")
        let initial = try XCTUnwrap(required(.fixture).frame, "Fixture has no initial frame")
        try recordOutsideState(at: CGPoint(x: initial.midX, y: initial.midY), label: "baseline-after-close")
        for cycle in 0..<4 {
            let label = "cycle-\(cycle + 1)"
            let (fixture, pid) = try raiseFixtureBeforePanel(label: label)
            let point = CGPoint(x: fixture.midX, y: fixture.midY)
            let opener = ["hotkey", "notch"][cycle % 2]
            try app.input.park()
            if opener == "hotkey" { try app.input.press("⌃⌥⌘N") }
            else { try app.input.click(at: trigger.point) }
            let panel = try settledPanel()
            XCTAssertFalse(panel.contains(point), "Fixture center must be outside the panel: \(point)")
            print("P1 outside cycle \(cycle + 1): \(opener), fixture=\(fixture), point=\(point)")
            try recordOutsideState(at: point, label: "\(label)-before-click")
            try requireFixtureClickTarget(at: point, fixture: fixture, pid: pid, label: label)
            try app.input.click(at: point)
            try expectPanelClosed()
            try recordOutsideState(at: point, label: "\(label)-after-close")
            expectWindowSetUnchanged()
            XCTAssertEqual(try required(.fixture).frame, fixture, "Outside click displaced or closed the fixture")
            try artifacts.step("outside-\(cycle + 1)-closed")
        }
    }

    func testOutsideClickGuardRefusesForeignWindow() throws {
        try app.launch(fixture: true)
        try recordWindowBaseline()
        let (fixture, pid) = try raiseFixtureBeforePanel(label: "refusal-start")
        try openPanel()
        let point = CGPoint(x: fixture.midX, y: fixture.midY)
        let primary = try XCTUnwrap(NSScreen.screens.first, "Missing primary screen")
        let small = NSRect(x: point.x - 40, y: primary.frame.maxY - point.y - 30, width: 80, height: 60)
        let covers: [(String, NSRect, NSWindow.Level, CGFloat)] = [
            ("floating", small, .floating, 1),
            ("lookalike", primary.frame, NSWindow.Level(rawValue: 1000), 0.25)
        ]
        for (label, frame, level, alpha) in covers {
            try requireFixtureClickTarget(at: point, fixture: fixture, pid: pid, label: "probe-before-\(label)")
            let cover = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            cover.isReleasedWhenClosed = false
            cover.level = level
            cover.alphaValue = alpha
            defer { cover.orderOut(nil); cover.close() }
            cover.orderFrontRegardless()
            let number = cover.windowNumber
            guard try waitUntil(timeout: 1, {
                try self.clickWindows().contains { $0.number == number }
            }) else { throw E2EFailure("Runner \(label) cover did not reach the on-screen window list") }
            var refusal: FixtureClickRefusal?
            do {
                try requireFixtureClickTarget(at: point, fixture: fixture, pid: pid, label: "probe-runner-\(label)")
            } catch let error as FixtureClickRefusal {
                refusal = error
                print("Outside guard rejected runner \(label) cover; no click was sent: \(error)")
            }
            cover.orderOut(nil)
            cover.close()
            let rejected = try XCTUnwrap(refusal, "Outside guard accepted the runner \(label) window; no click was sent")
            XCTAssertEqual(rejected.processID, Int(ProcessInfo.processInfo.processIdentifier))
            XCTAssertEqual(rejected.windowNumber, number, "Guard must reject our actual topmost runner window")
        }
        // Both probes only inspect the blocked point. Remove the runner's
        // windows before ordinary HID cleanup of the panel.
        try closePanel()
    }

    private func raiseFixtureBeforePanel(label: String) throws -> (CGRect, pid_t) {
        XCTAssertNil(try app.liveElement(.panel), "Fixture activation must happen while the panel is closed")
        try app.input.park()
        let node = try required(.fixture)
        let fixture = try XCTUnwrap(node.frame, "Fixture has no frame before activation")
        XCTAssertFalse(fixture.isEmpty, "Fixture has an empty frame before activation")
        let point = CGPoint(x: fixture.midX, y: fixture.midY)
        let pid = try XCTUnwrap(app.processID, "Missing fixture PID before activation")
        // Do this once while the panel is closed: activation cannot satisfy
        // the subsequent assertion that only the outside click closes it.
        app.application.activate()
        let result = AXUIElementPerformAction(node.element, kAXRaiseAction as CFString)
        guard result == .success else { throw E2EFailure("Fixture AXRaise failed: \(result.rawValue)") }
        print("Outside preparation \(label): one activate and one AXRaise, panel closed")
        let raised = try waitUntil(timeout: 1) {
            let first = try self.clickWindows().first {
                $0.alpha > 0 && $0.frame.contains(point) && !self.isSystemAutomationOverlay($0)
            }
            return first?.processID == Int(pid) && first.map { self.framesMatch($0.frame, fixture) } == true
        }
        try recordOutsideState(at: point, label: "\(label)-after-raise")
        guard raised else { throw E2EFailure("Fixture was not first within 1 s after one activate/AXRaise; no click was sent") }
        return (fixture, pid)
    }

    private func recordOutsideState(at point: CGPoint, label: String) throws {
        let front = NSWorkspace.shared.frontmostApplication
        let windows = try clickWindows().filter { $0.alpha > 0 && $0.frame.contains(point) }
        let eligible = windows.first { !isSystemAutomationOverlay($0) }
        let text = "\(label): uptime=\(ProcessInfo.processInfo.systemUptime), point=\(point)\n" +
            "frontmost=\(front?.localizedName ?? "none"), PID=\(front?.processIdentifier ?? -1), bundle=\(front?.bundleIdentifier ?? "none")\n" +
            "First raw hit: \(windows.first?.description ?? "none")\nFirst after system overlay: \(eligible?.description ?? "none")"
        print("Outside state: \(text)")
        try artifacts.text(text, name: "outside-state-\(label).txt")
    }

    private struct FixtureClickRefusal: Error, CustomStringConvertible {
        let processID: Int?
        let windowNumber: Int?
        let description: String
    }

    private struct ClickWindow {
        let number: Int
        let processID: Int
        let owner: String
        let layer: Int
        let frame: CGRect
        let alpha: Double
        let executablePath: String?
        var description: String {
            "owner=\(owner), PID=\(processID), layer=\(layer), number=\(number), bounds=\(frame), alpha=\(alpha), executable=\(executablePath ?? "unavailable")"
        }
    }

    private func clickWindows() throws -> [ClickWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            throw E2EFailure("Cannot read the on-screen click window list")
        }
        return try list.map { info in
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let processID = info[kCGWindowOwnerPID as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let alpha = info[kCGWindowAlpha as String] as? Double,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite) else {
                throw E2EFailure("Malformed on-screen window entry; no click was sent: \(info)")
            }
            return ClickWindow(number: number, processID: processID,
                               owner: info[kCGWindowOwnerName as String] as? String ?? "unknown",
                               layer: layer, frame: frame, alpha: alpha,
                               executablePath: NSRunningApplication(processIdentifier: pid_t(processID))?.executableURL?.path)
        }
    }

    private func framesMatch(_ actual: CGRect, _ expected: CGRect) -> Bool {
        zip([actual.minX, actual.minY, actual.maxX, actual.maxY],
            [expected.minX, expected.minY, expected.maxX, expected.maxY]).allSatisfy { abs($0 - $1) <= 1 }
    }

    private func isSystemAutomationOverlay(_ window: ClickWindow) -> Bool {
        window.owner == "AutomationModeUI" && window.layer == 1000 && window.alpha < 1 &&
            framesMatch(window.frame, CGDisplayBounds(CGMainDisplayID())) &&
            window.executablePath?.hasPrefix("/System/Library/PrivateFrameworks/AutomationMode.framework/") == true
    }

    private func requireFixtureClickTarget(at point: CGPoint, fixture: CGRect, pid: pid_t, label: String) throws {
        guard fixture.contains(point) else { throw E2EFailure("Click point is outside the fixture; no click was sent") }
        let windows = try clickWindows()
        var skipped: [ClickWindow] = []
        var first: ClickWindow?
        // Preserve front-to-back order and every layer. Only the verified
        // system automation overlay may be skipped; alpha/layer alone cannot.
        for window in windows where window.alpha > 0 && window.frame.contains(point) {
            if isSystemAutomationOverlay(window) { skipped.append(window) }
            else { first = window; break }
        }
        let diagnostics = "point=\(point); expected PID=\(pid), fixture=\(fixture)\n" +
            skipped.map { "Skipped system overlay: \($0.description)\n" }.joined() +
            "First hit: \(first?.description ?? "none")\nFirst 5 windows:\n" +
            windows.prefix(5).map(\.description).joined(separator: "\n")
        try artifacts.text(diagnostics, name: "outside-hit-\(label).txt")
        print("Fixture click target: \(diagnostics)")
        guard let first, first.processID == Int(pid), framesMatch(first.frame, fixture) else {
            throw FixtureClickRefusal(processID: first?.processID, windowNumber: first?.number,
                                      description: "Outside fixture click refused; no click was sent. \(diagnostics)")
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
            for (index, choice) in choices.enumerated() {
                let (title, expected) = choice
                // Only the first, untouched default supplies a release-state
                // baseline. M3 proved these Selection/No Delay comparisons.
                if index == 0 {
                    let before = try stableButton(control, label: "\(title)-before")
                    try select(title, in: control)
                    try expectValue(control, expected, message: "Menu did not select \(title)")
                    let after = try stableButton(control, label: "\(title)-released")
                    expectReleased(before, after, message: "\(control.rawValue) remained highlighted after \(title)")
                } else {
                    try select(title, in: control)
                    try expectValue(control, expected, message: "Menu did not select \(title)")
                }
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
    }

    func testMoreMenuClosesOnEsc() throws {
        try app.launch(fixture: true)
        try recordWindowBaseline()
        try openPanel()
        let before = try settledPanel()
        try openMenu(.panelMoreMenu)
        try app.input.park()
        try app.input.press("ESC")
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.visibleMenu == nil }, "More menu did not close after Esc")
        // A hide animation reaches orderOut after about 220 ms. Observe past
        // that point once, also allowing didEndTracking to restore the hotkey.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let after = try settledPanel(context: "Esc closed the panel together with the menu")
        for (actual, expected) in zip([after.minX, after.minY, after.width, after.height],
                                      [before.minX, before.minY, before.width, before.height]) {
            XCTAssertEqual(actual, expected, accuracy: 1,
                           "Esc closed the panel together with the menu: frame changed from \(before) to \(after)")
        }
        try artifacts.text("before=\(before)\nafter 0.4 s=\(after)", name: "first-esc-panel-frames.txt")
        try artifacts.step("menu-closed-by-esc")
        try app.input.press("ESC")
        try expectPanelClosed(message: "second Esc did not close the panel")
        expectWindowSetUnchanged()
        try artifacts.step("panel-closed-by-second-esc")
    }

    func testTabFollowsPointer() throws {
        try app.launch(fixture: true)
        _ = try required(.fixtureKeys)
        try recordWindowBaseline()
        try openPanel()
        try select("Scrolling", in: .panelModeMenu)
        try expectValue(.panelModeMenu, "Scrolling, down", message: "Scrolling was not selected")
        let counter = try required(.fixtureKeys)
        let counterValue = try counter.value
        let initialCount = try XCTUnwrap(Int(counterValue), "Fixture key counter is not numeric: \(counterValue)")
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
        XCTAssertNotNil(try app.liveElement(.panel), "Panel closed before the empty-window Tab")
        try app.input.press("TAB")
        let received = try waitUntil(timeout: 3) { try self.app.liveElement(.fixtureKeys)?.value == String(initialCount + 1) }
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
        try artifacts.text(String(pid), name: "quit-pid.txt")
        try app.expectQuit()
        try app.tap(.statusQuit)
        XCTAssertTrue(waitUntil(timeout: 5) { NSRunningApplication(processIdentifier: pid) == nil },
                      "process still alive 5 s after Quit")
        try artifacts.step("quit")
    }

    private func required(_ control: E2EApp.Control, message: String? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> AccessibilityNode {
        let exists = try waitUntil(timeout: 3) { try self.app.liveElement(control) != nil }
        XCTAssertTrue(exists, message ?? "Missing \(control.rawValue) before reading its value/frame", file: file, line: line)
        return try XCTUnwrap(app.liveElement(control), message ?? "Missing \(control.rawValue)", file: file, line: line)
    }

    private func tapLive(_ control: E2EApp.Control) throws {
        let target = try required(control)
        let frame = try XCTUnwrap(target.frame, "Missing hit target for \(control.rawValue)")
        XCTAssertFalse(frame.isEmpty, "Empty hit target for \(control.rawValue)")
        try app.input.click(at: CGPoint(x: frame.midX, y: frame.midY))
    }

    @discardableResult
    private func settledPanel(context: String? = nil) throws -> CGRect {
        _ = try required(.panel, message: context)
        let deadline = Date().addingTimeInterval(3)
        var previous: CGRect?
        var stable = 0
        repeat {
            if let frame = try app.liveElement(.panel)?.frame, !frame.isEmpty {
                stable = frame == previous ? stable + 1 : 0
                if stable >= 2 { return frame }
                previous = frame
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        XCTFail("\(context.map { $0 + "; " } ?? "")Panel frame did not settle in two consecutive 100 ms probes within 3 s")
        throw E2EFailure("Unsettled panel: \(String(describing: previous))")
    }

    private func openPanel() throws {
        try app.input.park()
        try app.input.press("⌃⌥⌘N")
        try settledPanel()
    }

    private func expectPanelClosed(message: String = "Panel did not disappear in 3 s") throws {
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.app.liveElement(.panel) == nil }, message)
        try app.input.park()
    }

    private func closePanel() throws {
        try tapLive(.panelClose)
        try expectPanelClosed()
        expectWindowSetUnchanged()
    }

    private var visibleMenu: AccessibilityNode? {
        get throws {
            try app.liveElement { try $0.role == kAXMenuRole && !($0.frame?.isEmpty ?? true) }
        }
    }

    private func openMenu(_ control: E2EApp.Control) throws {
        try app.input.park()
        try tapLive(control)
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.visibleMenu != nil }, "\(control.rawValue) did not open a menu")
    }

    private func select(_ title: String, in control: E2EApp.Control) throws {
        try app.input.park()
        let frame = try XCTUnwrap(required(control).frame, "Missing menu-button hit target")
        let start = CGPoint(x: frame.midX, y: frame.midY)
        var release = start
        var held = true
        try app.input.holdMouse(at: start)
        defer { if held { try? app.input.releaseMouse(at: release) } }
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.visibleMenu != nil }, "\(control.rawValue) did not open while pressed")
        let item = try visibleMenuItemFrame(title)
        release = CGPoint(x: item.midX, y: item.midY)
        // daf3bad/fabf326 lost the release and pointer exit inside NSMenu's
        // tracking loop. Keep the button down until the pointer leaves it
        // for the item, instead of releasing on the button before choosing.
        try app.input.dragHeldMouse(from: start, to: release)
        try app.input.releaseMouse(at: release)
        held = false
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.visibleMenu == nil }, "Menu did not close in 3 s after \(title)")
        try app.input.park()
    }

    private func visibleMenuItemFrame(_ title: String) throws -> CGRect {
        let menu = try XCTUnwrap(visibleMenu, "Menu disappeared before selecting \(title)")
        let item = try XCTUnwrap(menu.first { try $0.role == kAXMenuItemRole && $0.title == title }, "Missing menu item \(title)")
        let frame = try XCTUnwrap(item.frame, "Menu item \(title) has no frame")
        XCTAssertFalse(frame.isEmpty, "Menu item \(title) is hidden")
        return frame
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
        if try app.liveElement(.panel) != nil {
            print("Settings left the panel visible; closing with HID hotkey before the window baseline")
            try app.input.press("⌃⌥⌘N")
        }
        try expectPanelClosed()
        expectWindowSetUnchanged()
    }

    private func expectValue(_ control: E2EApp.Control, _ expected: String, message: String) throws {
        _ = try required(control)
        let matches = try waitUntil(timeout: 3) { try self.app.liveElement(control)?.value == expected }
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

    private func verifiedStatusItemFrame() throws -> CGRect {
        try app.input.park()
        try artifacts.text(app.application.debugDescription, name: "before-status-menu-tree.txt")
        let frame = try XCTUnwrap(required(.statusItem).frame, "Status item has no Accessibility frame")
        print("Status item frame: \(frame)")
        let pid = try XCTUnwrap(app.processID, "Missing process for status-item diagnostics")
        print("Status item PID: \(pid)")
        let windows = try StatusItemVisibility.windows(pid: pid, statusFrame: frame)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let windowText = String(decoding: try encoder.encode(windows), as: UTF8.self)
        try artifacts.text(windowText, name: "status-windows.json")
        let png = try artifacts.step("status-before-left-click")
        let visibility = try StatusItemVisibility.measure(png: png, frame: frame,
                                                          display: CGDisplayBounds(CGMainDisplayID()))
        let visibilityText = String(decoding: try encoder.encode(visibility), as: UTF8.self)
        try artifacts.text(visibilityText, name: "status-visibility.json")
        print("Status item visibility: \(visibilityText)")
        XCTAssertTrue(visibility.drawn,
                      "Status item is not drawn at its Accessibility frame \(frame): a menu bar manager or a crowded menu bar can hide it. On a notched display the menu bar has room for only a limited number of items; close menu bar apps or disconnect AirPods before the run; foreground \(visibility.foregroundPixels)/\(visibility.samplePixels); window list: \(windowText)")
        XCTAssertEqual(try required(.statusItem).frame, frame, "Status item moved during visibility check; no click was sent")
        return frame
    }

    private func openStatusMenu() throws {
        let frame = try verifiedStatusItemFrame()
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let windows = try clickWindows()
        let diagnostics = "point=\(point), primary display=\(CGDisplayBounds(CGMainDisplayID()))\nWindows at point (front to back):\n" +
            windows.filter { $0.alpha > 0 && $0.frame.contains(point) }.map(\.description).joined(separator: "\n")
        try artifacts.text(diagnostics, name: "status-click-hit.txt")
        print("Status click windows: \(diagnostics)")
        // Click exactly the frame whose pixels were checked. The window list
        // above is diagnostic: opening the menu proves input crossed the veil.
        try app.input.click(at: point)
        let opened = waitUntil(timeout: 1) { self.statusMenuIsVisible }
        try artifacts.step("status-after-left-click")
        print("Status menu HID left click: \(opened ? "opened" : "did not open")")
        try artifacts.text(app.application.debugDescription, name: "status-menu-tree.txt")
        XCTAssertTrue(opened, "Status menu did not open by HID left click")
        XCTAssertTrue(app.element(.statusSettings).exists, "Status menu is missing Settings")
        XCTAssertTrue(app.element(.statusQuit).exists, "Status menu is missing Quit")
        try artifacts.step("status-menu")
    }
}
