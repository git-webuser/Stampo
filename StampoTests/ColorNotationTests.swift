import AppKit
import Testing
@testable import Stampo

/// The inspector's colour field shows a colour in whatever notation the user
/// set as their default, so every notation the app prints it now also has to
/// read. Each case here is written against the app's own output rather than
/// against a guess at what people type.
@MainActor @Suite struct ColorNotationTests {

    private let sand = NSColor(srgbRed: 0.93, green: 0.89, blue: 0.85, alpha: 1)

    /// What is printed comes back as the same colour — the round trip is the
    /// whole promise of the field.
    @Test func everyNotationReadsItsOwnOutput() {
        for format in ColorSchemeType.allCases {
            let written = format.convert(sand)
            guard let parsed = format.parse(written)?.usingColorSpace(.sRGB) else {
                Issue.record("\(format.title) could not read its own \(written)")
                continue
            }
            // Rounded to whole numbers on the way out, so a percent of drift is
            // the format's own resolution rather than a mistake.
            #expect(abs(parsed.redComponent - sand.redComponent) < 0.02, "\(format.title) red")
            #expect(abs(parsed.greenComponent - sand.greenComponent) < 0.02, "\(format.title) green")
            #expect(abs(parsed.blueComponent - sand.blueComponent) < 0.02, "\(format.title) blue")
        }
    }

    /// Text arrives from the clipboard as often as from the keyboard: a hex
    /// pasted from a brand sheet has to work while the panel is set to RGB.
    @Test func aColourInAnotherNotationIsStillRead() {
        let parsed = ColorSchemeType.color(from: "#3A7BD5", preferring: .rgb)?
            .usingColorSpace(.sRGB)

        #expect(abs((parsed?.redComponent ?? 0) - 0x3A / 255) < 0.01)
        #expect(abs((parsed?.blueComponent ?? 0) - 0xD5 / 255) < 0.01)
    }

    /// HSL and HSB are written identically, so the setting is the only thing
    /// that can say which one "30° 33% 89%" means.
    @Test func theSettingDecidesBetweenHslAndHsb() {
        let text = "30° 33% 89%"
        let asHsl = ColorSchemeType.color(from: text, preferring: .hsl)?.usingColorSpace(.sRGB)
        let asHsb = ColorSchemeType.color(from: text, preferring: .hsb)?.usingColorSpace(.sRGB)

        #expect(asHsl != nil)
        #expect(asHsb != nil)
        #expect(abs((asHsl?.blueComponent ?? 0) - (asHsb?.blueComponent ?? 0)) > 0.05)
    }

    /// Separators and marks are noise around the numbers.
    @Test func theNumbersAreWhatMatters() {
        let plain = NSColor(rgbString: "237 227 217")?.usingColorSpace(.sRGB)
        let dressed = NSColor(rgbString: "rgb(237, 227, 217)")?.usingColorSpace(.sRGB)

        #expect(plain != nil)
        #expect(abs((plain?.redComponent ?? 0) - (dressed?.redComponent ?? 1)) < 0.001)
    }

    @Test func nonsenseIsNoColour() {
        #expect(ColorSchemeType.color(from: "", preferring: .hex) == nil)
        #expect(ColorSchemeType.color(from: "чёрный", preferring: .hex) == nil)
        #expect(NSColor(rgbString: "300 0 0") == nil)     // outside the range
        #expect(NSColor(cmykString: "10% 20% 30%") == nil) // three of four
    }
}
