import XCTest

@MainActor
final class Artifacts {
    let directory: URL
    private unowned let test: XCTestCase
    private var stepNumber = 0

    init(test: XCTestCase) throws {
        guard let path = ProcessInfo.processInfo.environment["STAMPO_E2E_ARTIFACTS"], !path.isEmpty else {
            throw E2EFailure("STAMPO_E2E_ARTIFACTS must name this run's artifact folder")
        }
        self.test = test
        directory = try Files.folder(URL(fileURLWithPath: path, isDirectory: true),
                                     "\(test.name.replacingOccurrences(of: "/", with: "-"))-\(UUID().uuidString)")
        let display = Input.primaryDisplayDescription
        try display.write(to: URL(fileURLWithPath: path).appendingPathComponent("primary-display.txt"),
                          atomically: true, encoding: .utf8)
        try text(display, name: "primary-display.txt")
        print("E2E primary display: \(display)")
        let seed = ProcessInfo.processInfo.environment["STAMPO_E2E_SEED"] ?? "missing"
        print("E2E seed: \(seed); scenario artifacts: \(directory.path)")
    }

    @discardableResult
    func step(_ name: String) throws -> URL {
        stepNumber += 1
        let label = String(format: "%02d-%@", stepNumber, name)
        let screenshot = XCUIScreen.main.screenshot()
        let url = directory.appendingPathComponent("\(label).png")
        try screenshot.pngRepresentation.write(to: url)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = label
        attachment.lifetime = .keepAlways
        test.add(attachment)
        return url
    }

    func text(_ value: String, name: String) throws {
        try value.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(string: value)
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    func failure(app: E2EApp) throws {
        try step("failure")
        if app.processID != nil { try text(app.application.debugDescription, name: "failure-tree.txt") }
        let log = try Files.run("/usr/bin/log", ["show", "--last", "2m", "--info", "--style", "compact",
                                               "--predicate", "subsystem == \"com.hex000.Stampo.e2e\""], in: directory)
        try text(log.output + log.error, name: "failure-log.txt")
    }
}
