import CoreGraphics
import Foundation

/// A document's page must stand apart from the card in either appearance.
nonisolated enum PageColor {
    static let lightCard = Presentation.Color.white
    static let darkCard = Presentation.Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255, alpha: 1)
    static let minimumContrast: CGFloat = 1.4
    static let complementSaturation: CGFloat = 0.55
    static let complementLightness: CGFloat = 0.50
    static let minimumHueSaturation: CGFloat = 0.08
    static let fallbackColor = Presentation.Color(red: 0.18, green: 0.43, blue: 0.92, alpha: 1)

    static func contrast(_ a: Presentation.Color, _ b: Presentation.Color) -> CGFloat {
        func luminance(_ color: Presentation.Color) -> CGFloat {
            func linear(_ channel: CGFloat) -> CGFloat {
                channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
        }
        let first = luminance(a)
        let second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    static func isVisible(_ color: Presentation.Color) -> Bool {
        contrast(color, lightCard) >= minimumContrast && contrast(color, darkCard) >= minimumContrast
    }

    /// The colour that says most about a picture: the one furthest from grey.
    static func characteristic(of colors: [Presentation.Color]) -> Presentation.Color {
        guard let best = colors.max(by: { saturation($0) < saturation($1) }) else {
            return fallbackColor
        }
        guard saturation(best) > minimumHueSaturation else {
            // A grey shot: keep its lightness rather than inventing a hue.
            return colors.max { $0.red + $0.green + $0.blue < $1.red + $1.green + $1.blue }
                ?? fallbackColor
        }
        return best
    }

    static func complement(of color: Presentation.Color) -> Presentation.Color {
        let high = max(color.red, max(color.green, color.blue))
        let low = min(color.red, min(color.green, color.blue))
        let delta = high - low
        var hue: CGFloat = 0
        if delta > 0 {
            if high == color.red {
                hue = (color.green - color.blue) / delta
            } else if high == color.green {
                hue = (color.blue - color.red) / delta + 2
            } else {
                hue = (color.red - color.green) / delta + 4
            }
            hue = (hue / 6 + 1).truncatingRemainder(dividingBy: 1)
        }
        hue = (hue + 0.5).truncatingRemainder(dividingBy: 1)
        let chroma = (1 - abs(2 * complementLightness - 1)) * complementSaturation
        let sector = hue * 6
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let channels: (CGFloat, CGFloat, CGFloat)
        switch sector {
        case ..<1: channels = (chroma, x, 0)
        case ..<2: channels = (x, chroma, 0)
        case ..<3: channels = (0, chroma, x)
        case ..<4: channels = (0, x, chroma)
        case ..<5: channels = (x, 0, chroma)
        default: channels = (chroma, 0, x)
        }
        let offset = complementLightness - chroma / 2
        return Presentation.Color(red: channels.0 + offset, green: channels.1 + offset,
                                  blue: channels.2 + offset, alpha: 1)
    }

    static func defaultColor(from colors: [Presentation.Color]) -> Presentation.Color {
        guard !colors.isEmpty else { return BackgroundDrawers.defaultStops[0] }
        let color = characteristic(of: colors)
        if isVisible(color) { return color }
        return saturation(color) > minimumHueSaturation
            ? complement(of: color) : BackgroundDrawers.defaultStops[0]
    }

    private static func saturation(_ color: Presentation.Color) -> CGFloat {
        let high = max(color.red, max(color.green, color.blue))
        let low = min(color.red, min(color.green, color.blue))
        return high > 0 ? (high - low) / high : 0
    }
}
