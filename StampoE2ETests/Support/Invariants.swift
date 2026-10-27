import ApplicationServices
import XCTest

@MainActor
final class Invariants {
    private let started = Date()
    private let initialCrashes: Set<String>
    private var initialWindows: Set<Int>?
    private let artifacts: Artifacts

    init(artifacts: Artifacts) throws {
        self.artifacts = artifacts
        initialCrashes = try Self.crashReports()
    }

    func recordWindowBaseline(app: E2EApp) throws {
        guard let pid = app.processID else { throw E2EFailure("Cannot record windows: E2E process is absent") }
        initialWindows = Self.windowIDs(pid: pid)
        try artifacts.text(Self.allWindowDescription(pid: pid), name: "windows-before.txt")
    }

    func check(app: E2EApp) throws {
        XCTAssertNotEqual(app.application.state, .notRunning, "E2E process died during the scenario")
        let newCrashes = try Self.crashReports().subtracting(initialCrashes)
        XCTAssertTrue(newCrashes.isEmpty, "New Stampo crash reports: \(newCrashes.sorted())")
        if let pid = app.processID {
            if let initialWindows {
                let settled = waitUntil(timeout: 3) { Self.windowIDs(pid: pid) == initialWindows }
                try artifacts.text(Self.allWindowDescription(pid: pid), name: "windows-after.txt")
                XCTAssertTrue(settled, "E2E full window set did not return to baseline: \(initialWindows) -> \(Self.windowIDs(pid: pid))")
            }
            // Bound the actual AX request rather than dispatching a potentially
            // hung XCUI query to another thread and leaving it running there.
            let root = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(root, 2)
            var children: CFTypeRef?
            let before = Date()
            let result = AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &children)
            let elapsed = Date().timeIntervalSince(before)
            XCTAssertEqual(result, .success, "E2E Accessibility tree did not answer: \(result.rawValue)")
            XCTAssertLessThanOrEqual(elapsed, 2, "E2E Accessibility tree took \(elapsed)s; limit is 2s")
        } else {
            XCTFail("The isolated E2E process is absent or its executable path changed")
        }
        try checkLog()
    }

    private func checkLog() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let result = try Files.run("/usr/bin/log", ["show", "--start", formatter.string(from: started),
            "--info", "--style", "json", "--predicate",
            "subsystem == \"com.hex000.Stampo.e2e\" AND messageType == error AND category IN {\"capture\", \"input\", \"panel\", \"settings\"}"], in: artifacts.directory)
        try artifacts.text(result.output, name: "app-errors.json")
        guard result.status == 0 else { throw E2EFailure("Cannot check unified log: \(result.error)") }
        guard let entries = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String: Any]] else {
            throw E2EFailure("Unified log did not return a JSON array")
        }
        guard let allowlistURL = Bundle(for: E2ETestCase.self).url(forResource: "log-allowlist", withExtension: "txt") else {
            throw E2EFailure("Missing Fixtures/log-allowlist.txt resource")
        }
        let lines = try String(contentsOf: allowlistURL, encoding: .utf8).components(separatedBy: .newlines)
        let allowed = try lines.compactMap { line -> String? in
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { return nil }
            let fields = line.components(separatedBy: " | ")
            guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty else {
                throw E2EFailure("Allowlist entry requires 'substring | reason': \(line)")
            }
            return fields[0]
        }
        let unexpected = entries.compactMap { entry -> String? in
            let message = entry["eventMessage"] as? String ?? String(describing: entry)
            return allowed.contains(where: { message.contains($0) }) ? nil : message
        }
        XCTAssertTrue(unexpected.isEmpty, "Unexpected E2E errors in capture/input/panel/settings: \(unexpected.joined(separator: "\n"))")
    }

    private static func crashReports() throws -> Set<String> {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("Stampo") && $0.hasSuffix(".ips") })
    }

    private static func windows(pid: pid_t, options: CGWindowListOption) -> [[String: Any]] {
        guard let values = CGWindowListCopyWindowInfo([options, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            XCTFail("Cannot query the WindowServer inventory")
            return []
        }
        return values.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) }
    }

    private static func windowIDs(pid: pid_t) -> Set<Int> {
        Set(windows(pid: pid, options: .optionAll).compactMap { $0[kCGWindowNumber as String] as? Int })
    }

    private static func allWindowDescription(pid: pid_t) -> String {
        String(describing: windows(pid: pid, options: .optionAll))
    }
}
