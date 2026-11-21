import AppKit
import ApplicationServices
import XCTest

@MainActor
final class HotkeyE2ETests: E2ETestCase {
    func testPanelAndPinHotkeys() throws {
        try app.launch(fixture: true)
        try recordWindowBaseline()

        try app.input.press("⌃⌥⌘N")
        _ = try settledPanel()
        _ = try required(.panelModeMenu)
        XCTAssertNil(try app.liveElement(.archiveBack), "Toggle hotkey opened Archive instead of Main")
        try artifacts.step("toggle-panel-main")
        try app.input.press("ESC")
        try expectClosed("Esc did not close Main opened by togglePanel")

        try app.input.press("⌃⌥⌘P")
        let pinnedFrame = try expectPinnedArchive(label: "collect-files-pinned")
        try clickFixtureOutsidePanel(frame: pinnedFrame, label: "pinned-archive")
        let disappeared = try waitUntil(timeout: 1) { try self.app.liveElement(.panel) == nil }
        XCTAssertFalse(disappeared, "Outside click closed the pinned archive")
        let retained = try expectPinnedArchive(label: "pinned-archive-after-outside-click")
        XCTAssertTrue(WindowHitTest.framesMatch(retained, pinnedFrame),
                      "Outside click changed the pinned archive frame: \(pinnedFrame) -> \(retained)")
        // openArchivePinned is a toggle: the same chord dismisses the pinned
        // archive, and hideAnimated clears its pin state.
        try app.input.press("⌃⌥⌘P")
        try expectClosed("Second collectFiles hotkey did not close the pinned archive")

        try app.input.press("⌃⌥⌘N")
        let mainFrame = try settledPanel()
        _ = try required(.panelModeMenu)
        XCTAssertNil(try app.liveElement(.archiveBack), "Reopening after pinned hide should return to Main")
        XCTAssertNil(try unpinButton(), "Hiding the archive left the reopened panel pinned")
        try artifacts.step("main-reopened-after-pinned-hide")
        // The outside click also probes whether a surviving pin still
        // suppresses auto-hide on Main.
        try clickFixtureOutsidePanel(frame: mainFrame, label: "reopened-main")
        try expectClosed("Outside click did not close Main reopened after pinned hide")

        try app.input.press("⌃⌥⌘P")
        try expectPinnedArchive(label: "collect-files-pinned-again")
        // Pinning prevents outside dismissal, not the archive's Esc owner.
        // With no expanded stack or selection, escapeAction is hidePanel.
        try app.input.press("ESC")
        try expectClosed("Esc did not close the pinned archive with no inner layers")
    }

    @discardableResult
    private func expectPinnedArchive(label: String) throws -> CGRect {
        _ = try required(.archiveBack)
        let frame = try settledPanel()
        XCTAssertNil(try app.liveElement(.panelModeMenu), "collectFiles did not route to Archive")
        let pinned = try waitUntil(timeout: 3) { try self.unpinButton() != nil }
        XCTAssertTrue(pinned, "collectFiles did not expose the existing Unpin panel button")
        try artifacts.text(app.application.debugDescription, name: "\(label)-tree.txt")
        try artifacts.step(label)
        return frame
    }

    private func unpinButton() throws -> AccessibilityNode? {
        try app.liveElement {
            try $0.role == kAXButtonRole && $0.attribute(kAXDescriptionAttribute) as? String == "Unpin panel"
        }
    }

    private func clickFixtureOutsidePanel(frame: CGRect, label: String) throws {
        try app.input.park()
        let fixture = try required(.fixture)
        let fixtureFrame = try XCTUnwrap(fixture.frame, "Fixture has no outside-click frame")
        let point = CGPoint(x: fixtureFrame.midX, y: fixtureFrame.midY)
        XCTAssertFalse(frame.contains(point), "Fixture center must be outside the panel")
        let pid = try XCTUnwrap(app.processID, "Missing fixture PID")

        app.application.activate()
        let raised = AXUIElementPerformAction(fixture.element, kAXRaiseAction as CFString)
        guard raised == .success else { throw E2EFailure("Fixture AXRaise failed: \(raised.rawValue)") }
        let firstIsFixture = try waitUntil(timeout: 1) {
            let first = try WindowHitTest.windows().first {
                $0.alpha > 0 && $0.frame.contains(point) && !WindowHitTest.isSystemAutomationOverlay($0)
            }
            return first?.processID == Int(pid) && first.map { WindowHitTest.framesMatch($0.frame, fixtureFrame) } == true
        }
        XCTAssertTrue(firstIsFixture, "Fixture was not first after one activate/AXRaise")
        let afterActivation = try settledPanel()
        XCTAssertTrue(WindowHitTest.framesMatch(afterActivation, frame),
                      "Fixture activation changed the panel before outside click: \(frame) -> \(afterActivation)")
        try WindowHitTest.requireOwnedTarget(at: point, frame: fixtureFrame, pid: pid, label: label, artifacts: artifacts)
        try app.input.click(at: point)
    }

    private func required(_ control: E2EApp.Control) throws -> AccessibilityNode {
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.app.liveElement(control) != nil },
                      "Missing \(control.rawValue); AX errors must throw")
        return try XCTUnwrap(app.liveElement(control))
    }

    private func settledPanel() throws -> CGRect {
        _ = try required(.panel)
        var previous: CGRect?
        var stable = 0
        var result: CGRect?
        let settled = try waitUntil(timeout: 3) {
            guard let frame = try self.app.liveElement(.panel)?.frame, !frame.isEmpty else {
                stable = 0
                return false
            }
            stable = frame == previous ? stable + 1 : 0
            previous = frame
            result = frame
            return stable >= 2
        }
        XCTAssertTrue(settled, "Hotkey panel frame did not settle")
        return try XCTUnwrap(result)
    }

    private func expectClosed(_ message: String) throws {
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.app.liveElement(.panel) == nil }, message)
        expectWindowSetUnchanged()
    }
}
