import AppKit
import Combine

// MARK: - Tray Item

enum TrayItem: Identifiable, Equatable {
    case color(TrayColor)
    case screenshot(TrayScreenshot)

    var id: UUID {
        switch self {
        case .color(let c):      return c.id
        case .screenshot(let s): return s.id
        }
    }
}

struct TrayColor: Identifiable, Equatable {
    let id = UUID()
    let color: NSColor
    let hex: String
}

struct TrayScreenshot: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

// MARK: - ColorSchemeType

enum ColorSchemeType: CaseIterable, Equatable {
    case hex
    case rgb
    case hsl
    case hsb
    case cmyk

    var title: String {
        switch self {
        case .hex:  return "HEX"
        case .rgb:  return "RGB"
        case .hsl:  return "HSL"
        case .hsb:  return "HSB"
        case .cmyk: return "CMYK"
        }
    }

    func convert(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        switch self {
        case .hex:  return c.hexString
        case .rgb:  return c.rgbString
        case .hsl:  return c.hslString
        case .hsb:  return c.hsbString
        case .cmyk: return c.cmykString
        }
    }
}

// MARK: - NotchTrayModel

final class NotchTrayModel: ObservableObject {
    @Published private(set) var items: [TrayItem] = []

    // Hardcoded for now, will move to Settings later
    private let maxItems = 20

    var colors: [TrayColor] {
        items.compactMap {
            if case .color(let c) = $0 { return c } else { return nil }
        }
    }

    func add(color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        let hex = c.hexString

        items.removeAll {
            if case .color(let existing) = $0 { return existing.hex == hex }
            return false
        }
        items.insert(.color(TrayColor(color: c, hex: hex)), at: 0)
        trim()
    }

    func add(screenshotURL url: URL) {
        items.removeAll {
            if case .screenshot(let s) = $0 { return s.url == url }
            return false
        }
        items.insert(.screenshot(TrayScreenshot(url: url)), at: 0)
        trim()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    private func trim() {
        // When over limit, remove oldest items from the tail.
        // For screenshots, also delete the file from disk.
        guard items.count > maxItems else { return }
        let excess = items.suffix(from: maxItems)
        for item in excess {
            if case .screenshot(let s) = item {
                do {
                    try FileManager.default.removeItem(at: s.url)
                } catch {
                    #if DEBUG
                    print("[TrayModel] removeItem failed: \(error)")
                    #endif
                }
            }
        }
        items = Array(items.prefix(maxItems))
    }
}
