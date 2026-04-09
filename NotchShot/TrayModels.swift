import AppKit
import Combine
import Foundation

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

// MARK: - Tray Persistence (Codable)

private struct PersistedTrayItem: Codable {
    enum Kind: String, Codable { case color, screenshot }
    let kind: Kind
    let hex:  String?   // color items
    let path: String?   // screenshot items
}

// MARK: - NotchTrayModel

final class NotchTrayModel: ObservableObject {
    @Published private(set) var items: [TrayItem] = []

    private var cancellables = Set<AnyCancellable>()

    init() {
        restoreIfNeeded()
        // Persist whenever items change and persistTray is on
        $items
            .dropFirst()
            .sink { [weak self] _ in self?.persistIfNeeded() }
            .store(in: &cancellables)
    }

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
        let limit = AppSettings.trayMaxItems
        guard items.count > limit else { return }
        let excess = items.suffix(from: limit)
        for item in excess {
            if case .screenshot(let s) = item {
                try? FileManager.default.removeItem(at: s.url)
            }
        }
        items = Array(items.prefix(limit))
    }

    // MARK: Persistence

    private func persistIfNeeded() {
        guard AppSettings.persistTray else { return }
        let encoded: [PersistedTrayItem] = items.compactMap {
            switch $0 {
            case .color(let c):
                return PersistedTrayItem(kind: .color, hex: c.hex, path: nil)
            case .screenshot(let s):
                return PersistedTrayItem(kind: .screenshot, hex: nil, path: s.url.path)
            }
        }
        if let data = try? JSONEncoder().encode(encoded) {
            UserDefaults.standard.set(data, forKey: AppSettings.Keys.trayPersistedData)
        }
    }

    private func restoreIfNeeded() {
        guard AppSettings.persistTray,
              let data = UserDefaults.standard.data(forKey: AppSettings.Keys.trayPersistedData),
              let decoded = try? JSONDecoder().decode([PersistedTrayItem].self, from: data)
        else { return }

        let restored: [TrayItem] = decoded.compactMap { p in
            switch p.kind {
            case .color:
                guard let hex = p.hex, let color = NSColor(hexString: hex) else { return nil }
                return .color(TrayColor(color: color, hex: hex))
            case .screenshot:
                guard let path = p.path else { return nil }
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                return .screenshot(TrayScreenshot(url: url))
            }
        }
        items = restored
    }


}
