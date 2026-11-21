import AppKit
import ApplicationServices
import XCTest

@MainActor
final class ArchiveEscapeE2ETests: E2ETestCase {
    // Archive hide uses 0.12 s of content dissolve + 0.22 s of hide animation.
    // The rest of this interval allows for the intervening Task and orderOut.
    private let archiveLayerObservation: TimeInterval = 0.6
    private var clipboard: ClipboardSnapshot?
    private var clickNumber = 0
    private var changeCountBeforeCommandClick: Int?

    override func setUpWithError() throws {
        try super.setUpWithError()
        clipboard = try ClipboardSnapshot()
    }

    override func tearDownWithError() throws {
        // Restore before common teardown can report a failure. Keep every
        // process/window/AX/log/crash/input invariant from E2ETestCase.
        var restorationError: Error?
        do {
            if let disposition = try clipboard?.restoreIfChanged() {
                print("Pasteboard restoration: \(disposition)")
                try artifacts.text(disposition, name: "pasteboard-restoration.txt")
            }
        } catch { restorationError = error }
        try super.tearDownWithError()
        if let restorationError { throw restorationError }
    }

    func testEscUnwindsOneLayerPerPress() throws {
        let frame = try prepareArchive()

        try app.input.press("ESC")
        try observeArchiveState(expanded: false, selecting: true, frame: frame, label: "esc-1")
        try app.input.press("ESC")
        try observeArchiveState(expanded: false, selecting: false, frame: frame, label: "esc-2")
        try app.input.press("ESC")
        RunLoop.current.run(until: Date().addingTimeInterval(archiveLayerObservation))
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.app.liveElement(.panel) == nil },
                      "Third Esc did not close the panel")
        expectWindowSetUnchanged()
        try artifacts.step("esc-3-closed")
        let count = try XCTUnwrap(changeCountBeforeCommandClick)
        XCTAssertEqual(NSPasteboard.general.changeCount, count, "⌘-click copied to the pasteboard")
        try artifacts.text("unchanged=\(NSPasteboard.general.changeCount == count)", name: "command-click-pasteboard.txt")
    }

    func testBackUnwindsTheSameLadder() throws {
        let frame = try prepareArchive()
        try artifacts.text(app.application.debugDescription, name: "before-back-tree.txt")
        let backFrame = try XCTUnwrap(required("stampo.archive.back").frame)
        try artifacts.text("back=\(backFrame)\npanel=\(frame)", name: "back-target-frame.txt")
        XCTAssertEqual(backFrame.width, 32, accuracy: 1, "Back target must match its explicit 32 pt cell, not the archive container")
        XCTAssertEqual(backFrame.height, 24, accuracy: 1, "Back target must match its explicit 24 pt cell")
        try click("stampo.archive.back")
        try observeArchiveState(expanded: false, selecting: true, frame: frame, label: "back-1")
        try click("stampo.archive.back")
        try observeArchiveState(expanded: false, selecting: false, frame: frame, label: "back-2")
        try click("stampo.archive.back")
        RunLoop.current.run(until: Date().addingTimeInterval(archiveLayerObservation))
        let mainFrame = try settledPanel()
        _ = try required(E2EApp.Control.panelModeMenu.rawValue)
        XCTAssertNil(try app.liveElement(.archiveBack), "Third Back did not leave the archive")
        XCTAssertNil(try app.liveElement(.archiveSelection), "Third Back left selection active")
        try artifacts.text("archive=\(frame)\nmain=\(mainFrame)", name: "back-3-frames.txt")
        try artifacts.step("back-3-main-still-visible")
        // Cleanup is a separate real hotkey, after Main was observed alive.
        try app.input.press("⌃⌥⌘N")
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.app.liveElement(.panel) == nil }, "Cleanup hotkey did not close Main")
        expectWindowSetUnchanged()
    }

    func testEscClosesMenuBeforeUnwinding() throws {
        let frame = try prepareArchive()
        try click(E2EApp.Control.archiveColorFormat.rawValue)
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.visibleMenu != nil }, "Archive color-format menu did not open")
        try artifacts.step("archive-menu-open")
        try app.input.press("ESC")
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.visibleMenu == nil }, "First Esc did not close the archive menu")
        try observeArchiveState(expanded: true, selecting: true, frame: frame, label: "menu-esc-1-layers-retained",
                                missingPanel: "First Esc closed the panel together with the archive menu")
        try app.input.press("ESC")
        try observeArchiveState(expanded: false, selecting: true, frame: frame, label: "menu-esc-2-stack-collapsed")
        try app.input.press("ESC")
        try observeArchiveState(expanded: false, selecting: false, frame: frame, label: "menu-esc-3-selection-exited")
        try app.input.press("ESC")
        RunLoop.current.run(until: Date().addingTimeInterval(archiveLayerObservation))
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.app.liveElement(.panel) == nil }, "Fourth Esc did not close the panel after the menu and layers")
        expectWindowSetUnchanged()
        try artifacts.step("menu-esc-4-panel-closed")
    }

    private var visibleMenu: AccessibilityNode? {
        get throws {
            try app.liveElement { try $0.role == kAXMenuRole && !($0.frame?.isEmpty ?? true) }
        }
    }

    private func prepareArchive() throws -> CGRect {
        try app.launch(archive: true)
        try recordWindowBaseline()
        try app.input.press("⌃⌥⌘N")
        _ = try settledPanel()
        try click("stampo.panel.archiveToggle")
        _ = try required("stampo.archive.back")
        for index in 0..<5 { _ = try required("stampo.archive.cell.\(index)") }
        // A plain stack click expands; Command-clicking a COLOR leaf selects
        // without invoking its ordinary Copy action (archiveTapIntent).
        try click("stampo.archive.cell.4")
        for index in 0..<3 { _ = try required("stampo.archive.stack.member.\(index)") }
        let color = try required("stampo.archive.cell.0")
        let colorFrame = try XCTUnwrap(color.frame)
        // The existing Color label is shown on hover. Reveal it by moving over
        // our AX cell before asserting its identity; no click has been sent.
        try app.input.move(to: CGPoint(x: colorFrame.midX, y: colorFrame.midY))
        let labelVisible = try waitUntil(timeout: 1) {
            let cell = try self.required("stampo.archive.cell.0")
            return try cell.first { node in
                try node.attribute(kAXDescriptionAttribute) as? String == "Color #FF6B4A"
            } != nil
        }
        XCTAssertTrue(labelVisible, "Cell 0 is not the expected Color #FF6B4A leaf before Command-click")
        guard labelVisible else { throw E2EFailure("Command-click target is not the expected color leaf") }
        try artifacts.text(app.application.debugDescription, name: "before-command-click-tree.txt")
        try artifacts.text("Color #FF6B4A", name: "command-click-color-label.txt")
        changeCountBeforeCommandClick = NSPasteboard.general.changeCount
        try click("stampo.archive.cell.0", command: true)
        let frame = try settledPanel()
        try expectArchiveState(expanded: true, selecting: true, frame: frame, label: "prepared")

        return frame
    }

    private func required(_ identifier: String) throws -> AccessibilityNode {
        let found = try waitUntil(timeout: 3) { try self.app.liveElement { try $0.identifier == identifier } != nil }
        XCTAssertTrue(found, "Missing \(identifier); failed AX reads must throw")
        return try XCTUnwrap(app.liveElement { try $0.identifier == identifier })
    }

    private func settledPanel() throws -> CGRect {
        _ = try required(E2EApp.Control.panel.rawValue)
        var previous: CGRect?
        var stable = 0
        var frame: CGRect?
        let deadline = Date().addingTimeInterval(3)
        repeat {
            frame = try app.liveElement(.panel)?.frame
            if let current = frame, !current.isEmpty {
                stable = current == previous ? stable + 1 : 0
                previous = current
                if stable >= 2 { return current }
            } else { stable = 0 }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        XCTFail("Panel frame did not settle in two consecutive 100 ms probes")
        throw E2EFailure("Panel frame did not settle: \(String(describing: frame))")
    }

    private func click(_ identifier: String, command: Bool = false) throws {
        let target = try XCTUnwrap(required(identifier).frame, "Missing hit target \(identifier)")
        XCTAssertFalse(target.isEmpty)
        let frame = try settledPanel()
        let point = CGPoint(x: target.midX, y: target.midY)
        let pid = try XCTUnwrap(app.processID, "Missing bound PID before a panel click")
        // Approach the target only after the unchanged ownership gate. The
        // cursor has its own WindowServer window; leave it at another point
        // inside our panel while reading the target's front-to-back list.
        let away = CGPoint(x: point.x + 48 < frame.maxX ? point.x + 48 : point.x - 48, y: point.y)
        XCTAssertTrue(frame.contains(away))
        try app.input.move(to: away)
        _ = try waitUntil(timeout: 1) {
            let first = try WindowHitTest.windows().first {
                $0.alpha > 0 && $0.frame.contains(point) && !WindowHitTest.isSystemAutomationOverlay($0)
            }
            return first?.processID == Int(pid) && first.map { WindowHitTest.framesMatch($0.frame, frame) } == true
        }
        clickNumber += 1
        try WindowHitTest.requireOwnedTarget(at: point, frame: frame, pid: pid,
                                            label: "archive-\(clickNumber)", artifacts: artifacts, context: "panel")
        if command { try app.input.commandClick(at: point) }
        else { try app.input.click(at: point) }
        // Both mouse-down monitors defer handling to a Task, which reads the
        // current pointer position. Leaving immediately can classify this
        // inside click as outside. Keep the pointer here until AX confirms
        // the result because the race depends on main-thread timing.
    }

    private func observeArchiveState(expanded: Bool, selecting: Bool, frame: CGRect, label: String,
                                     missingPanel: String? = nil) throws {
        RunLoop.current.run(until: Date().addingTimeInterval(archiveLayerObservation))
        XCTAssertNotNil(try app.liveElement(.panel),
                        missingPanel ?? "Missing stampo.panel.window at \(label): an archive layer should remain")
        try expectArchiveState(expanded: expanded, selecting: selecting, frame: frame, label: label)
    }

    private func expectArchiveState(expanded: Bool, selecting: Bool, frame: CGRect, label: String) throws {
        let current = try settledPanel()
        XCTAssertTrue(WindowHitTest.framesMatch(current, frame), "\(label): surviving panel changed frame: \(frame) -> \(current)")
        _ = try required("stampo.archive.back")
        XCTAssertNil(try app.liveElement(.panelModeMenu), "\(label): archive returned to Main")
        for index in 0..<3 {
            let member = try app.liveElement { try $0.identifier == "stampo.archive.stack.member.\(index)" }
            XCTAssertEqual(member != nil, expanded, "\(label): stack member \(index) has wrong visibility")
        }
        let selection = try app.liveElement(.archiveSelection)
        XCTAssertEqual(selection != nil, selecting, "\(label): selection mode has wrong state")
        if selecting {
            let count = try XCTUnwrap(selection).value
            XCTAssertEqual(count, "1", "\(label): selected color was lost")
            let cell = try required("stampo.archive.cell.0")
            let mark = try XCTUnwrap(cell.first { try $0.identifier == "stampo.archive.selectionMark" }, "Selected color has no AX selection mark")
            XCTAssertEqual(try mark.value, "Selected", "\(label): color selection mark lost its value")
        }
        try artifacts.text("expanded=\(expanded)\nselecting=\(selecting)\nframe=\(current)", name: "\(label)-state.txt")
        try artifacts.step(label)
    }
}
