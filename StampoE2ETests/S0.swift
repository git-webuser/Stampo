import XCTest

@MainActor
final class S0: E2ETestCase {
    func testPanelLifecycle() throws {
        try app.launch()
        try artifacts.step("launched")

        XCTAssertTrue(app.element(.statusItem).exists, "Stampo status item must be present after launch")
        try recordWindowBaseline()
        try artifacts.step("status-item")

        try app.input.press("⌃⌥⌘N")
        XCTAssertTrue(app.element(.panel).waitForExistence(timeout: 5), "Panel did not open after the global ⌃⌥⌘N hotkey")
        try artifacts.step("panel-open")

        for control in [E2EApp.Control.panelModeMenu, .panelDelayMenu, .panelArchiveToggle] {
            XCTAssertTrue(app.element(control).waitForExistence(timeout: 3), "Panel is missing required control \(control.rawValue)")
        }
        try artifacts.step("panel-controls")

        try app.tap(.panelClose)
        try app.input.park()
        XCTAssertTrue(waitUntil(timeout: 5) { !self.app.element(.panel).exists }, "Panel remained open after Close panel")
        try artifacts.step("panel-closed")
    }
}
