import AppKit
import Darwin
import XCTest

@MainActor
final class E2EApp {
    enum Control: String {
        case fixtureKeys = "stampo.e2e.fixture.keys"
        case panelMoreMenu = "stampo.panel.moreMenu"
        case statusSettings = "stampo.statusMenu.settings"
        case statusQuit = "stampo.statusMenu.quit"
        case fixture = "stampo.e2e.fixture"
        case editorCanvas = "stampo.editor.canvas"
        case statusItem = "stampo.status.item"
        case panel = "stampo.panel.window"
        case panelClose = "stampo.panel.close"
        case panelModeMenu = "stampo.panel.modeMenu"
        case panelDelayMenu = "stampo.panel.delayMenu"
        case panelArchiveToggle = "stampo.panel.archiveToggle"
    }

    let application: XCUIApplication
    let input: Input
    let directory: URL
    private let appURL: URL
    private(set) var launched = false
    private let executableURL: URL
    private(set) var boundProcessID: pid_t?
    private(set) var accessibilityProbeExpected = false
    private(set) var quitExpected = false
    var expectedQuitProcessID: pid_t? { quitExpected ? boundProcessID : nil }
    var terminationExpected: Bool { quitExpected || accessibilityProbeExpected }

    func terminateForAccessibilityProbe() throws {
        guard processID != nil else { throw E2EFailure("Missing process before the AX termination probe") }
        accessibilityProbeExpected = true
        terminate()
    }

    func expectQuit() throws {
        guard processID != nil else { throw E2EFailure("Missing process before expected Quit") }
        quitExpected = true
    }

    init(directory: URL) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["STAMPO_E2E_APP_PATH"], !path.isEmpty else {
            throw E2EFailure("STAMPO_E2E_APP_PATH must name the separately signed copy")
        }
        appURL = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard appURL.path.contains("/build/e2e/"), appURL.lastPathComponent == "Stampo-E2E.app",
              let bundle = Bundle(url: appURL), bundle.bundleIdentifier == "com.hex000.Stampo.e2e",
              let executable = bundle.executableURL else {
            throw E2EFailure("Refusing to launch an app outside build/e2e or without the isolated .e2e id: \(path)")
        }
        executableURL = executable.resolvingSymlinksInPath()
        // Presence-only safety check; target PID discovery happens in launch().
        guard !NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.hex000.Stampo" || $0.bundleIdentifier == "com.hex000.Stampo.e2e"
        }) else {
            throw E2EFailure("Close all Stampo copies before testing; the harness never closes the user's copy")
        }
        self.directory = directory
        input = try Input()
        application = XCUIApplication(url: appURL)
    }

    func launch(fixture: Bool = false, editorPNG: URL? = nil) throws {
        guard !launched else { throw E2EFailure("The E2E application has already been launched") }
        let captures = try Files.folder(directory, "captures")
        application.launchArguments = ["-StampoE2E", "-preferredLanguage", "en",
                                       "-saveDirectory", captures.path, "-hasCompletedOnboarding", "YES"]
        if fixture { application.launchArguments.append("-StampoE2EFixture") }
        if let editorPNG { application.launchArguments += ["-StampoE2EOpenEditor", editorPNG.path] }
        application.launchEnvironment["STAMPO_E2E_ARTIFACTS"] = directory.path
        application.launch()
        launched = true
        // Discover this launch only inside a bounded wait, then bind once.
        var discoveredPID: pid_t?
        guard waitUntil(timeout: 8, {
            guard let candidate = NSRunningApplication.runningApplications(withBundleIdentifier: "com.hex000.Stampo.e2e")
                .first(where: { $0.bundleURL?.resolvingSymlinksInPath() == self.appURL })?.processIdentifier,
                  self.isOwnedLiveProcess(candidate) else { return false }
            discoveredPID = candidate
            return true
        }), let discoveredPID else {
            throw E2EFailure("E2E launch did not produce a live process at its executable path in 8s")
        }
        boundProcessID = discoveredPID
        print("E2E bound launch PID: \(discoveredPID), executable: \(executableURL.path)")
        // LSUIElement readiness comes from the status item, not activation.
        guard element(.statusItem).waitForExistence(timeout: 8), processID != nil else {
            throw E2EFailure("E2E launch did not create a live status item in 8s (state=\(application.state.rawValue))")
        }
        try input.park()
    }

    var processID: pid_t? {
        guard let boundProcessID, isOwnedLiveProcess(boundProcessID) else { return nil }
        return boundProcessID
    }

    private func isOwnedLiveProcess(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro unavailable in Swift.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return false }
        let actual = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
        return actual == executableURL
    }

    func element(_ control: Control) -> XCUIElement {
        application.descendants(matching: .any)[control.rawValue].firstMatch
    }

    func tap(_ control: Control, file: StaticString = #filePath, line: UInt = #line) throws {
        let target = element(control)
        guard target.waitForExistence(timeout: 3) else {
            XCTFail("Missing control \(control.rawValue) before tap", file: file, line: line)
            throw E2EFailure("Missing control \(control.rawValue)")
        }
        let frame = target.frame
        guard !frame.isEmpty, frame.minX.isFinite, frame.minY.isFinite else {
            throw E2EFailure("Control \(control.rawValue) has no finite hit target: \(frame)")
        }
        try input.click(at: CGPoint(x: frame.midX, y: frame.midY))
    }

    func terminate() {
        guard launched, processID != nil else { return }
        application.terminate()
    }
}

@MainActor
@discardableResult
func waitUntil(timeout: TimeInterval, _ condition: () throws -> Bool) rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if try condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    } while Date() < deadline
    return try condition()
}
