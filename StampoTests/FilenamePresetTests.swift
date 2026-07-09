import Foundation
import Testing
@testable import Stampo

@Suite struct FilenamePresetTests {

    /// 2026-04-12 14:30:05 in the current calendar/time zone — resolveFilename
    /// formats components in `.current`, so the fixture must be built the same way.
    private static let fixtureDate: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 12
        comps.hour = 14; comps.minute = 30; comps.second = 5
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: comps)!
    }()

    @Test func compactPreset() {
        let name = AppSettings.resolveFilename(
            preset: .compact, date: Self.fixtureDate, counter: 1, format: "png")
        #expect(name == "Apr·12-14·30·05.png")
    }

    @Test func isoPreset() {
        let name = AppSettings.resolveFilename(
            preset: .iso, date: Self.fixtureDate, counter: 1, format: "png")
        #expect(name == "2026-04-12 14-30-05.png")
    }

    @Test func numberedPresetUsesCounter() {
        let name = AppSettings.resolveFilename(
            preset: .numbered, date: Self.fixtureDate, counter: 98, format: "png")
        #expect(name == "2026-04-12 #98.png")
    }

    @Test func densePreset() {
        let name = AppSettings.resolveFilename(
            preset: .dense, date: Self.fixtureDate, counter: 1, format: "png")
        #expect(name == "20260412-143005.png")
    }

    @Test(arguments: [
        ("png", "png"), ("jpg", "jpg"), ("tiff", "tiff"),
        ("gif", "png"), ("", "png"),  // unknown formats fall back to png
    ])
    func extensionResolution(format: String, expected: String) {
        let name = AppSettings.resolveFilename(
            preset: .dense, date: Self.fixtureDate, counter: 1, format: format)
        #expect(name.hasSuffix(".\(expected)"))
    }

    @Test func singleDigitComponentsAreZeroPadded() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 1; comps.day = 5
        comps.hour = 7; comps.minute = 8; comps.second = 9
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let date = cal.date(from: comps)!
        let name = AppSettings.resolveFilename(
            preset: .iso, date: date, counter: 1, format: "png")
        #expect(name == "2026-01-05 07-08-09.png")
    }
}
