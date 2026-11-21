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

    func recordWindowBaseline(primePanelCache: Bool = true) throws {
        if !primePanelCache {
            try invariants?.recordWindowBaseline(app: app)
            return
        }
        // The panel is created lazily and retained after orderOut. Prime that
        // cache through real input, so full window-id sets can be compared
        // without silently exempting new hidden windows from leak detection.
        try app.input.press("⌃⌥⌘N")
        XCTAssertTrue(app.element(.panel).waitForExistence(timeout: 5), "Panel cache warmup did not open the panel")
        try artifacts.step("baseline-panel-open")
        try app.tap(.panelClose)
        XCTAssertTrue(waitUntil(timeout: 5) { !self.app.element(.panel).exists }, "Panel cache warmup did not close the panel")
        try app.input.park()
        try artifacts.step("baseline-panel-closed")
        try invariants?.recordWindowBaseline(app: app)
    }

    func captureWindowBaseline(name: String) throws -> Invariants.WindowBaseline {
        guard let invariants else { throw E2EFailure("Missing invariant recorder") }
        return try invariants.captureWindowBaseline(app: app, name: name)
    }

    func expectWindowSetUnchanged(baseline: Invariants.WindowBaseline? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let failures = invariants?.windowFailures(app: app, baseline: baseline) ?? ["Missing invariant recorder"]
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"), file: file, line: line)
    }

    override func tearDownWithError() throws {
        guard let app else { return }
        defer { app.terminate() }
        var failures = app.input.releasePressedState()
        if app.launched { failures += invariants?.check(app: app) ?? [] }
        if (testRun?.failureCount ?? 0) > 0 || !failures.isEmpty {
            do { try artifacts.failure(app: app) }
            catch { failures.append("Cannot collect failure artifacts: \(error)") }
        }
        // Complete evidence and cleanup before recording any new assertion.
        app.terminate()
        if !failures.isEmpty { XCTFail(failures.joined(separator: "\n")) }
    }
}
