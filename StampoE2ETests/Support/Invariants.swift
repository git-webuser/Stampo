import ApplicationServices
import XCTest

@MainActor
final class Invariants {
    private let started = Date()
    private let initialCrashes: Set<String>
    private var initialWindows: Set<String>?
    private let artifacts: Artifacts

    init(artifacts: Artifacts) throws {
        self.artifacts = artifacts
        initialCrashes = try Self.crashReports()
    }

    func recordWindowBaseline(app: E2EApp) throws {
        guard let pid = app.processID else { throw E2EFailure("Cannot record windows: E2E process is absent") }
        initialWindows = try Self.windowStates(pid: pid)
        try artifacts.text(try Self.allWindowDescription(pid: pid), name: "windows-before.txt")
    }

    func check(app: E2EApp) -> [String] {
        // Return diagnostics, rather than asserting here: XCTest may abort a
        // teardown assertion before the caller can save evidence or terminate.
        var failures: [String] = []
        if app.application.state == .notRunning { failures.append("E2E process died during the scenario") }
        do {
            let newCrashes = try Self.crashReports().subtracting(initialCrashes)
            if !newCrashes.isEmpty { failures.append("New Stampo crash reports: \(newCrashes.sorted())") }
        } catch { failures.append("Cannot inspect crash reports: \(error)") }
        if let pid = app.processID {
            if let initialWindows {
                let settled = waitUntil(timeout: 3) { (try? Self.windowStates(pid: pid)) == initialWindows }
                do {
                    try artifacts.text(try Self.allWindowDescription(pid: pid), name: "windows-after.txt")
                    if !settled {
                        failures.append("E2E full window set did not return to baseline: \(initialWindows) -> \(try Self.windowStates(pid: pid))")
                    }
                } catch { failures.append("Cannot inspect E2E windows: \(error)") }
            }
            let root = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(root, 2)
            var children: CFTypeRef?
            let before = Date()
            let result = AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &children)
            let elapsed = Date().timeIntervalSince(before)
            if result != .success { failures.append("E2E Accessibility tree did not answer: \(result.rawValue)") }
            if elapsed > 2 { failures.append("E2E Accessibility tree took \(elapsed)s; limit is 2s") }
        } else {
            failures.append("The isolated E2E process is absent or its executable path changed")
        }
        do { failures += try checkLog() } catch { failures.append("Cannot check unified log: \(error)") }
        return failures
    }

    private func checkLog() throws -> [String] {
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
        return unexpected.isEmpty ? [] : ["Unexpected E2E errors in capture/input/panel/settings: \(unexpected.joined(separator: "\n"))"]
    }

    private static func crashReports() throws -> Set<String> {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("Stampo") && $0.hasSuffix(".ips") })
    }

    private static func windows(pid: pid_t, options: CGWindowListOption) throws -> [[String: Any]] {
        guard let values = CGWindowListCopyWindowInfo([options, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw E2EFailure("Cannot query the WindowServer inventory")
        }
        return values.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) }
    }

    private static func windowStates(pid: pid_t) throws -> Set<String> {
        Set(try windows(pid: pid, options: .optionAll).compactMap { window in
            guard let number = window[kCGWindowNumber as String] as? Int else { return nil }
            let visible = window[kCGWindowIsOnscreen as String] as? Bool ?? false
            return "\(number):onScreen=\(visible)"
        })
    }

    private static func allWindowDescription(pid: pid_t) throws -> String {
        String(describing: try windows(pid: pid, options: .optionAll))
    }
}
