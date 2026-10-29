import AppKit
import CoreGraphics

/// Shared front-to-back ownership guard. Extracted unchanged from P1;
/// alpha/layer alone never exempts an overlay or another owned window.
@MainActor
enum WindowHitTest {
    struct Refusal: Error, CustomStringConvertible {
        let processID: Int?
        let windowNumber: Int?
        let description: String
    }

    struct Window {
        let number: Int
        let processID: Int
        let owner: String
        let layer: Int
        let frame: CGRect
        let alpha: Double
        let executablePath: String?
        var description: String {
            "owner=\(owner), PID=\(processID), layer=\(layer), number=\(number), bounds=\(frame), alpha=\(alpha), executable=\(executablePath ?? "unavailable")"
        }
    }

    static func windows() throws -> [Window] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            throw E2EFailure("Cannot read the on-screen click window list")
        }
        return try list.map { info in
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let processID = info[kCGWindowOwnerPID as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let alpha = info[kCGWindowAlpha as String] as? Double,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite) else {
                throw E2EFailure("Malformed on-screen window entry; no click was sent: \(info)")
            }
            return Window(number: number, processID: processID,
                               owner: info[kCGWindowOwnerName as String] as? String ?? "unknown",
                               layer: layer, frame: frame, alpha: alpha,
                               executablePath: NSRunningApplication(processIdentifier: pid_t(processID))?.executableURL?.path)
        }
    }

    static func framesMatch(_ actual: CGRect, _ expected: CGRect) -> Bool {
        zip([actual.minX, actual.minY, actual.maxX, actual.maxY],
            [expected.minX, expected.minY, expected.maxX, expected.maxY]).allSatisfy { abs($0 - $1) <= 1 }
    }

    static func isSystemAutomationOverlay(_ window: Window) -> Bool {
        window.owner == "AutomationModeUI" && window.layer == 1000 && window.alpha < 1 &&
            framesMatch(window.frame, CGDisplayBounds(CGMainDisplayID())) &&
            window.executablePath?.hasPrefix("/System/Library/PrivateFrameworks/AutomationMode.framework/") == true
    }

    static func requireOwnedTarget(at point: CGPoint, frame fixture: CGRect, pid: pid_t, label: String, artifacts: Artifacts, context: String = "fixture") throws {
        guard fixture.contains(point) else { throw E2EFailure("Click point is outside the \(context); no click was sent") }
        let windows = try windows()
        var skipped: [Window] = []
        var first: Window?
        // Preserve front-to-back order and every layer. Only the verified
        // system automation overlay may be skipped; alpha/layer alone cannot.
        for window in windows where window.alpha > 0 && window.frame.contains(point) {
            if isSystemAutomationOverlay(window) { skipped.append(window) }
            else { first = window; break }
        }
        let diagnostics = "point=\(point); expected PID=\(pid), \(context)=\(fixture)\n" +
            skipped.map { "Skipped system overlay: \($0.description)\n" }.joined() +
            "First hit: \(first?.description ?? "none")\nFirst 5 windows:\n" +
            windows.prefix(5).map(\.description).joined(separator: "\n")
        try artifacts.text(diagnostics, name: "outside-hit-\(label).txt")
        print("\(context.capitalized) click target: \(diagnostics)")
        guard let first, first.processID == Int(pid), framesMatch(first.frame, fixture) else {
            throw Refusal(processID: first?.processID, windowNumber: first?.number,
                                      description: "Outside \(context) click refused; no click was sent. \(diagnostics)")
        }
    }

}
