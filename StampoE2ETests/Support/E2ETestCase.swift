import XCTest

@MainActor
class E2ETestCase: XCTestCase {
    var app: E2EApp!
    var artifacts: Artifacts!
    private var invariants: Invariants?

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 90
        artifacts = try Artifacts(test: self)
        invariants = try Invariants(artifacts: artifacts)
        app = try E2EApp(directory: artifacts.directory)
        addUIInterruptionMonitor(withDescription: "User handles system permissions") { alert in
            // Never allow XCTest's default handlers to grant a permission.
            XCTFail("System permission dialog requires the user: \(alert.debugDescription)")
            return true
        }
    }

    func recordWindowBaseline() throws {
        // The panel is created lazily and retained after orderOut. Prime that
        // cache through real input, so full window-id sets can be compared
        // without silently exempting new hidden windows from leak detection.
        try app.input.press("⌃⌥⌘N")
        XCTAssertTrue(app.element(.panel).waitForExistence(timeout: 5), "Panel cache warmup did not open the panel")
        try artifacts.step("baseline-panel-open")
        try app.tap(.panelClose)
        try app.input.park()
        XCTAssertTrue(waitUntil(timeout: 5) { !self.app.element(.panel).exists }, "Panel cache warmup did not close the panel")
        try artifacts.step("baseline-panel-closed")
        try invariants?.recordWindowBaseline(app: app)
    }

    override func tearDownWithError() throws {
        guard let app else { return }
        defer { app.terminate() }
        do {
            if app.launched { try invariants?.check(app: app) }
        } catch {
            XCTFail("Cannot verify E2E invariants: \(error)")
        }
        if (testRun?.failureCount ?? 0) > 0 { try artifacts.failure(app: app) }
    }
}
