import CoreGraphics
import Foundation
import Testing
@testable import Stampo

nonisolated enum PageColorSamples {
    static func color(_ hex: Int) -> Presentation.Color {
        Presentation.Color(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    static let documents = [0xFAFAFA, 0x1E1E1E, 0xC7D4E0, 0xDCE8FF, 0xFF8000, 0xEEF4FF]

    // Recorded from the inspector before moving its implementation.
    static var baselines: [([Presentation.Color], Presentation.Color)] {
        let fallback = Presentation.Color(red: 0.18, green: 0.43, blue: 0.92, alpha: 1)
        let grey = Presentation.Color(red: 0.71, green: 0.714, blue: 0.722, alpha: 1)
        let pale = Presentation.Color(red: 0.78, green: 0.831, blue: 0.878, alpha: 1)
        let red = color(0xFF0000)
        let boundary = Presentation.Color(red: 1, green: 0.92, blue: 0.92, alpha: 1)
        let above = Presentation.Color(red: 1, green: 0.919, blue: 0.919, alpha: 1)
        return [([], fallback), ([.white], .white), ([.black], .black),
                ([.black, grey, .white], .white), ([grey, pale, red, .white], red),
                ([grey, pale, .white], pale), ([boundary, .white], .white),
                ([above, .white], above), ([red, pale, red], red)]
    }
}

@Suite struct PageColorTests {
    @Test func contrastUsesRelativeSRGBLuminance() {
        #expect(PageColor.contrast(.white, .white) == 1)
        #expect(abs(PageColor.contrast(.white, .black) - 21) < 1e-12)
        #expect(PageColor.contrast(.white, .black) == PageColor.contrast(.black, .white))
        #expect(abs(PageColor.contrast(.white, PageColorSamples.color(0x1E1E1E)) - 16.671156) < 0.00001)
    }

    @Test func aPageMustStandApartFromBothCards() {
        for hex in [0xFAFAFA, 0xEDEDED, 0x1E1E1E, 0x000000, 0xDCE8FF, 0xEEF4FF] {
            #expect(!PageColor.isVisible(PageColorSamples.color(hex)), "\(String(hex, radix: 16))")
        }
        for hex in [0xB5B6B8, 0xC7D4E0, 0xFF8000] {
            #expect(PageColor.isVisible(PageColorSamples.color(hex)))
        }
        #expect(PageColor.lightCard == .white)
        #expect(PageColor.darkCard == PageColorSamples.color(0x1E1E1E))
    }

    @Test func characteristicMatchesAllNineRecordedBaselines() {
        for (colors, expected) in PageColorSamples.baselines {
            #expect(PageColor.characteristic(of: colors) == expected)
        }
    }

    @Test func complementsTurnSixKnownHuesHalfACircle() {
        let inputs = [0xFF0000, 0xFFFF00, 0x00FF00, 0x00FFFF, 0x0000FF, 0xFF00FF]
        let expected: [(CGFloat, CGFloat, CGFloat)] = [
            (0.225, 0.775, 0.775), (0.225, 0.225, 0.775), (0.775, 0.225, 0.775),
            (0.775, 0.225, 0.225), (0.775, 0.775, 0.225), (0.225, 0.775, 0.225)
        ]
        for (hex, channels) in zip(inputs, expected) {
            let result = PageColor.complement(of: PageColorSamples.color(hex))
            #expect(abs(result.red - channels.0) < 1e-12)
            #expect(abs(result.green - channels.1) < 1e-12)
            #expect(abs(result.blue - channels.2) < 1e-12)
            let high = max(result.red, max(result.green, result.blue))
            let low = min(result.red, min(result.green, result.blue))
            let lightness = (high + low) / 2
            let saturation = (high - low) / (1 - abs(2 * lightness - 1))
            #expect(abs(lightness - 0.50) < 1e-12)
            #expect(abs(saturation - 0.55) < 1e-12)
            #expect(result.alpha == 1)
        }
    }

    @Test func everyComplementIsVisibleOnBothCards() {
        let wheel = [PageColorSamples.color(0xFF0000), PageColorSamples.color(0xFFFF00),
                     PageColorSamples.color(0x00FF00), PageColorSamples.color(0x00FFFF),
                     PageColorSamples.color(0x0000FF), PageColorSamples.color(0xFF00FF)]
        for degree in 0..<360 {
            let a = wheel[degree / 60]
            let b = wheel[(degree / 60 + 1) % 6]
            let fraction = CGFloat(degree % 60) / 60
            let input = Presentation.Color(red: a.red + (b.red - a.red) * fraction,
                                           green: a.green + (b.green - a.green) * fraction,
                                           blue: a.blue + (b.blue - a.blue) * fraction, alpha: 1)
            let result = PageColor.complement(of: input)
            #expect(PageColor.contrast(result, .white) >= 1.7, "hue \(degree)")
            #expect(PageColor.contrast(result, PageColorSamples.color(0x1E1E1E)) >= 2, "hue \(degree)")
        }
    }

    @Test func invisibleNeutralsAndMissingSamplesUseTheAccentBlue() {
        let accent = BackgroundDrawers.defaultStops[0]
        #expect(PageColor.defaultColor(from: []) == accent)
        for hex in [0xFAFAFA, 0xFFFFFF, 0xEDEDED, 0x1E1E1E, 0x000000, 0xEEF4FF] {
            #expect(PageColor.defaultColor(from: [PageColorSamples.color(hex)]) == accent)
        }
    }

    @Test func visibleCharacteristicColoursStayThemselves() {
        for hex in [0xB5B6B8, 0xC7D4E0, 0xFF8000] {
            let color = PageColorSamples.color(hex)
            #expect(PageColor.defaultColor(from: [color]) == color)
        }
    }

    @Test func invisibleColoursWithAHueUseTheirComplement() {
        let pale = PageColorSamples.color(0xDCE8FF)
        let result = PageColor.defaultColor(from: [pale])
        #expect(result == PageColor.complement(of: pale))
        // #DCE8FF is 219 3/7 degrees: the complement is 39 3/7.
        #expect(abs(result.red - 0.775) < 1e-12)
        #expect(abs(result.green - 0.5864285714285714) < 1e-12)
        #expect(abs(result.blue - 0.225) < 1e-12)
    }

    @Test func theHueThresholdIsStrict() {
        let boundary = Presentation.Color(red: 1, green: 0.92, blue: 0.92, alpha: 1)
        let above = Presentation.Color(red: 1, green: 0.919, blue: 0.919, alpha: 1)
        #expect(PageColor.defaultColor(from: [boundary]) == BackgroundDrawers.defaultStops[0])
        #expect(PageColor.defaultColor(from: [above]) == PageColor.complement(of: above))
    }

    /// Window appearance must never become an input to document data.
    @Test func theRuleHasNoAppKitDependency() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Stampo/Editor/PageColor.swift"),
                                encoding: .utf8)
        for forbidden in ["import AppKit", "NSAppearance", "NSColor", "NSApp"] {
            #expect(!source.contains(forbidden), "PageColor depends on \(forbidden)")
        }
    }
}
