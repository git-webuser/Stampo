import AppKit
import XCTest

@MainActor
final class S0b: E2ETestCase {
    func testFixtureWindowPixels() throws {
        executionTimeAllowance = 30
        try app.launch(fixture: true)
        let fixture = app.element(.fixture)
        XCTAssertTrue(fixture.waitForExistence(timeout: 3), "Fixture window must exist before sampling its content")
        let frame = fixture.frame
        XCTAssertEqual(frame.width, 300, accuracy: 0.5, "Fixture content must remain 300 points wide")
        XCTAssertGreaterThanOrEqual(frame.height, 200, "Fixture frame must contain 200 points of content")
        try recordWindowBaseline(primePanelCache: false)
        let png = try artifacts.step("fixture-pixels")
        let bitmap = try Files.Bitmap(png: png)
        let display = CGDisplayBounds(CGMainDisplayID())
        let scale = CGFloat(bitmap.width) / display.width
        // The window's frame includes a titlebar. Its 300×200 content ends
        // at the frame's bottom in Quartz; the titlebar is above that content.
        let content = CGRect(x: frame.midX - 150, y: frame.maxY - 200, width: 300, height: 200)
        for (side, fraction, expected) in [("left", CGFloat(0.25), [255, 0, 0]),
                                            ("right", CGFloat(0.75), [0, 0, 255])] {
            let center = CGPoint(x: (content.minX + content.width * fraction - display.minX) * scale,
                                 y: (content.midY - display.minY) * scale)
            let mean = try meanRGB(bitmap, center: center)
            let message = "Fixture \(side): expected (\(expected.map(String.init).joined(separator: ","))), got (\(mean.map(String.init).joined(separator: ","))); tolerance ±2"
            print(message)
            XCTAssertTrue(zip(mean, expected).allSatisfy { abs($0 - $1) <= 2 }, message)
        }
    }

    func testOpenEditorHook() throws {
        executionTimeAllowance = 30
        let source = try XCTUnwrap(Bundle(for: S0b.self).url(forResource: "editor-hook", withExtension: "png"),
                                  "The tiny editor-hook PNG must be a test bundle resource")
        let local = artifacts.directory.appendingPathComponent("editor-hook.png")
        try FileManager.default.copyItem(at: source, to: local)
        try app.launch(editorPNG: local)
        XCTAssertTrue(app.element(.editorCanvas).waitForExistence(timeout: 5),
                      "The editor hook did not expose stampo.editor.canvas")
        // This scenario intentionally retains the editor opened at startup.
        try recordWindowBaseline(primePanelCache: false)
        try artifacts.step("editor-hook")
    }

    private func meanRGB(_ bitmap: Files.Bitmap, center: CGPoint) throws -> [Int] {
        let x0 = Int(center.x.rounded()) - 22
        let y0 = Int(center.y.rounded()) - 22
        var sum = [Int](repeating: 0, count: 3)
        for y in y0..<(y0 + 44) {
            for x in x0..<(x0 + 44) {
                let pixel = try bitmap.rgba(x: x, y: y)
                for channel in 0..<3 { sum[channel] += Int(pixel[channel]) }
            }
        }
        return sum.map { Int((Double($0) / Double(44 * 44)).rounded()) }
    }
}
