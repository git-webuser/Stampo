import AppKit
import Testing
@testable import Stampo

@Suite struct NSColorFormatTests {

    private let red   = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    private let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    private let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private let gray  = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)

    @Test func hexStrings() {
        #expect(red.hexString == "#FF0000")
        #expect(black.hexString == "#000000")
        #expect(white.hexString == "#FFFFFF")
        #expect(gray.hexString == "#808080")
    }

    @Test func rgbStrings() {
        #expect(red.rgbString == "255 0 0")
        #expect(gray.rgbString == "128 128 128")
    }

    @Test func hslStrings() {
        #expect(red.hslString == "0° 100% 50%")
        #expect(white.hslString == "0° 0% 100%")
        #expect(black.hslString == "0° 0% 0%")
    }

    @Test func hsbStrings() {
        #expect(red.hsbString == "0° 100% 100%")
        #expect(black.hsbString == "0° 0% 0%")
    }

    @Test func cmykStrings() {
        #expect(red.cmykString == "0% 100% 100% 0%")
        #expect(black.cmykString == "0% 0% 0% 100%")
        #expect(white.cmykString == "0% 0% 0% 0%")
    }

    @Test func greenAndBlueHueBranches() {
        let green = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        let blue  = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        #expect(green.hslString == "120° 100% 50%")
        #expect(blue.hslString == "240° 100% 50%")
    }
}
