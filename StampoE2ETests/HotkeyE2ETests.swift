import AppKit
import ApplicationServices
import XCTest

@MainActor
final class HotkeyE2ETests: E2ETestCase {
    func testPanelAndPinHotkeys() throws {
        try app.launch()
        try recordWindowBaseline()

        try app.input.press("⌃⌥⌘N")
        _ = try settledPanel()
        _ = try required(.panelModeMenu)
        XCTAssertNil(try app.liveElement(.archiveBack), "Toggle hotkey opened Archive instead of Main")
        try artifacts.step("toggle-panel-main")
        try app.input.press("ESC")
        try expectClosed("Esc did not close Main opened by togglePanel")

        try app.input.press("⌃⌥⌘P")
        try expectPinnedArchive(label: "collect-files-pinned")
        // openArchivePinned is a toggle: the same chord dismisses the pinned
        // archive, and hideAnimated clears its pin state.
        try app.input.press("⌃⌥⌘P")
        try expectClosed("Second collectFiles hotkey did not close the pinned archive")

        try app.input.press("⌃⌥⌘P")
        try expectPinnedArchive(label: "collect-files-pinned-again")
        // Pinning prevents outside dismissal, not the archive's Esc owner.
        // With no expanded stack or selection, escapeAction is hidePanel.
        try app.input.press("ESC")
        try expectClosed("Esc did not close the pinned archive with no inner layers")
    }

    private func expectPinnedArchive(label: String) throws {
        _ = try required(.archiveBack)
        _ = try settledPanel()
        XCTAssertNil(try app.liveElement(.panelModeMenu), "collectFiles did not route to Archive")
        let pinned = try waitUntil(timeout: 3) {
            try self.app.liveElement {
                try $0.role == kAXButtonRole && $0.attribute(kAXDescriptionAttribute) as? String == "Unpin panel"
            } != nil
        }
        XCTAssertTrue(pinned, "collectFiles did not expose the existing Unpin panel button")
        try artifacts.text(app.application.debugDescription, name: "\(label)-tree.txt")
        try artifacts.step(label)
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
