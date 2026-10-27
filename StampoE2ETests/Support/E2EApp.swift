import AppKit
import XCTest

@MainActor
final class E2EApp {
    enum Control: String {
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

    init(directory: URL) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["STAMPO_E2E_APP_PATH"], !path.isEmpty else {
            throw E2EFailure("STAMPO_E2E_APP_PATH must name the separately signed copy")
        }
        appURL = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard appURL.path.contains("/build/e2e/"), appURL.lastPathComponent == "Stampo-E2E.app",
              let bundle = Bundle(url: appURL), bundle.bundleIdentifier == "com.hex000.Stampo.e2e" else {
            throw E2EFailure("Refusing to launch an app outside build/e2e or without the isolated .e2e id: \(path)")
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.hex000.Stampo").isEmpty,
              NSRunningApplication.runningApplications(withBundleIdentifier: "com.hex000.Stampo.e2e").isEmpty else {
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
        // LSUIElement normally stays in background. Its status item, rather
        // than foreground activation or a document window, establishes readiness.
        guard element(.statusItem).waitForExistence(timeout: 8), processID != nil else {
            throw E2EFailure("E2E launch did not create a status item in 8s (state=\(application.state.rawValue))")
        }
        try input.park()
    }

    var processID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.hex000.Stampo.e2e")
            .first { $0.bundleURL?.resolvingSymlinksInPath() == appURL }?.processIdentifier
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
func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    } while Date() < deadline
    return condition()
}
