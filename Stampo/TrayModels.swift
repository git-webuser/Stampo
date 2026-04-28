import AppKit
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

@Observable final class NotchTrayModel {
    private(set) var items: [TrayItem] = []

    private var persistWorkItem: DispatchWorkItem?
    @ObservationIgnored private var fileWatchers: [UUID: DispatchSourceFileSystemObject] = [:]

    private func schedulePersist() {
        persistWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.persistIfNeeded() }
        persistWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    init() {
        restoreIfNeeded()
    }

    deinit {
        fileWatchers.values.forEach { $0.cancel() }
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
        schedulePersist()
    }

    func add(screenshotURL url: URL) {
        items.removeAll {
            if case .screenshot(let s) = $0 {
                if s.url == url { stopWatching(id: s.id); return true }
            }
            return false
        }
        let shot = TrayScreenshot(url: url)
        items.insert(.screenshot(shot), at: 0)
        startWatching(shot)
        trim()
        schedulePersist()
    }

    func remove(id: UUID) {
        stopWatching(id: id)
        items.removeAll { $0.id == id }
        schedulePersist()
    }

    func remove(screenshotURL url: URL) {
        items.removeAll {
            if case .screenshot(let s) = $0, s.url == url {
                stopWatching(id: s.id)
                return true
            }
            return false
        }
        schedulePersist()
    }

    private func trim() {
        let limit = AppSettings.trayMaxItems
        guard items.count > limit else { return }
        items = Array(items.prefix(limit))
        schedulePersist()
    }

    // MARK: File Watching

    private func startWatching(_ shot: TrayScreenshot) {
        let path = shot.url.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.delete, .rename],
            queue: .main
        )

        let shotID = shot.id
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if !FileManager.default.fileExists(atPath: path) {
                self.remove(id: shotID)
            }
        }
        source.setCancelHandler { close(fd) }

        fileWatchers[shot.id] = source
        source.resume()
    }

    private func stopWatching(id: UUID) {
        fileWatchers.removeValue(forKey: id)?.cancel()
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
        for case .screenshot(let shot) in items { startWatching(shot) }
    }


}
