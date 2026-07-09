import AppKit
import Testing
@testable import Stampo

@Suite struct ColorSchemeTypeTests {

    private let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

    @Test func titles() {
        #expect(ColorSchemeType.hex.title == "HEX")
        #expect(ColorSchemeType.rgb.title == "RGB")
        #expect(ColorSchemeType.hsl.title == "HSL")
        #expect(ColorSchemeType.hsb.title == "HSB")
        #expect(ColorSchemeType.cmyk.title == "CMYK")
    }

    @Test func convertMatchesUnderlyingFormatters() {
        #expect(ColorSchemeType.hex.convert(red) == "#FF0000")
        #expect(ColorSchemeType.rgb.convert(red) == "255 0 0")
        #expect(ColorSchemeType.hsl.convert(red) == "0° 100% 50%")
        #expect(ColorSchemeType.hsb.convert(red) == "0° 100% 100%")
        #expect(ColorSchemeType.cmyk.convert(red) == "0% 100% 100% 0%")
    }

    @Test func allCasesCovered() {
        #expect(ColorSchemeType.allCases.count == 5)
    }
}
