import AppKit
import ApplicationServices
import XCTest

@MainActor
final class ArchiveEscapeE2ETests: E2ETestCase {
    private var clipboard: ClipboardSnapshot?
    private var clickNumber = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        clipboard = try ClipboardSnapshot()
    }

    override func tearDownWithError() throws {
        // Restore before common teardown can report a failure. Keep every
        // process/window/AX/log/crash/input invariant from E2ETestCase.
        var restorationError: Error?
        do { try clipboard?.restoreIfChanged() } catch { restorationError = error }
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.app.liveElement(.panel) == nil },
                      "Third Esc did not close the panel")
        expectWindowSetUnchanged()
        try artifacts.step("esc-3-closed")
    }

    func testBackUnwindsTheSameLadder() throws {
        let frame = try prepareArchive()
        try artifacts.text(app.application.debugDescription, name: "before-back-tree.txt")
        let backFrame = try XCTUnwrap(required("stampo.archive.back").frame)
        try artifacts.text("back=\(backFrame)\npanel=\(frame)", name: "back-target-frame.txt")
        try click("stampo.archive.back")
        try observeArchiveState(expanded: false, selecting: true, frame: frame, label: "back-1")
        try click("stampo.archive.back")
        try observeArchiveState(expanded: false, selecting: false, frame: frame, label: "back-2")
        try click("stampo.archive.back")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let mainFrame = try panelFrame()
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

    private func prepareArchive() throws -> CGRect {
        try app.launch(archive: true)
        try recordWindowBaseline()
        try app.input.press("⌃⌥⌘N")
        _ = try panelFrame()
        try click("stampo.panel.archiveToggle")
        _ = try required("stampo.archive.back")
        for index in 0..<5 { _ = try required("stampo.archive.cell.\(index)") }
        // A plain stack click expands; Command-clicking a COLOR leaf selects
        // without invoking its ordinary Copy action (archiveTapIntent).
        try click("stampo.archive.cell.4")
        for index in 0..<3 { _ = try required("stampo.archive.stack.member.\(index)") }
        try click("stampo.archive.cell.0", command: true)
        let frame = try panelFrame()
        try expectArchiveState(expanded: true, selecting: true, frame: frame, label: "prepared")

        return frame
    }

    private func required(_ identifier: String) throws -> AccessibilityNode {
        let found = try waitUntil(timeout: 3) { try self.app.liveElement { try $0.identifier == identifier } != nil }
        XCTAssertTrue(found, "Missing \(identifier); failed AX reads must throw")
        return try XCTUnwrap(app.liveElement { try $0.identifier == identifier })
    }

    private func panelFrame() throws -> CGRect {
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
        let frame = try panelFrame()
        let point = CGPoint(x: target.midX, y: target.midY)
        let pid = try XCTUnwrap(app.processID, "Missing bound PID before a panel click")
        clickNumber += 1
        try WindowHitTest.requireOwnedTarget(at: point, frame: frame, pid: pid,
                                            label: "archive-\(clickNumber)", artifacts: artifacts, context: "panel")
        if command { try app.input.commandClick(at: point) }
        else { try app.input.click(at: point) }
        // The scenario observes the click result before leaving the cell.
        // Moving outside here is an extra action: the app's async mouse-down
        // monitor reads the current pointer position, not the event position.
    }

    private func observeArchiveState(expanded: Bool, selecting: Bool, frame: CGRect, label: String) throws {
        // Observe beyond the 0.22 s hide animation: an about-to-hide panel
        // cannot satisfy the assertion that the surviving layers stay put.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        try expectArchiveState(expanded: expanded, selecting: selecting, frame: frame, label: label)
    }

    private func expectArchiveState(expanded: Bool, selecting: Bool, frame: CGRect, label: String) throws {
        let current = try panelFrame()
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
