import AppKit
import Foundation

// MARK: - Tray Item

enum TrayItem: Identifiable, Equatable {
    case color(TrayColor)
    case screenshot(TrayScreenshot)
    case text(TrayText)

    var id: UUID {
        switch self {
        case .color(let c):      return c.id
        case .screenshot(let s): return s.id
        case .text(let t):       return t.id
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

/// A plain-text entity captured via OCR or Scan Code.
struct TrayText: Identifiable, Equatable {
    let id = UUID()
    let text: String

    /// First non-empty line — used as the compact cell caption.
    var firstLine: String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
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
    enum Kind: String, Codable { case color, screenshot, text }
    let kind: Kind
    let hex:  String?   // color items
    let path: String?   // screenshot items
    let text: String?   // text items
}

// MARK: - NotchTrayModel

@Observable final class NotchTrayModel {
    private(set) var items: [TrayItem] = []

    private var persistWorkItem: DispatchWorkItem?
    @ObservationIgnored private var fileWatchers: [UUID: DispatchSourceFileSystemObject] = [:]
    /// Thumbnail loaders outlive individual SwiftUI cells and hosting views.
    /// Without this cache, recreating the panel briefly replaces every preview
    /// with the placeholder while the same files are decoded again.
    @ObservationIgnored private var thumbnailLoaders: [UUID: ThumbnailLoader] = [:]

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

    func add(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.removeAll {
            if case .text(let existing) = $0 { return existing.text == trimmed }
            return false
        }
        items.insert(.text(TrayText(text: trimmed)), at: 0)
        trim()
        schedulePersist()
    }

    func add(screenshotURL url: URL) {
        items.removeAll {
            if case .screenshot(let s) = $0 {
                if s.url == url {
                    stopWatching(id: s.id)
                    thumbnailLoaders.removeValue(forKey: s.id)
                    return true
                }
            }
            return false
        }
        let shot = TrayScreenshot(url: url)
        prepareThumbnail(for: shot)
        items.insert(.screenshot(shot), at: 0)
        startWatching(shot)
        trim()
        schedulePersist()
    }

    func remove(id: UUID) {
        stopWatching(id: id)
        thumbnailLoaders.removeValue(forKey: id)
        items.removeAll { $0.id == id }
        schedulePersist()
    }

    func remove(screenshotURL url: URL) {
        items.removeAll {
            if case .screenshot(let s) = $0, s.url == url {
                stopWatching(id: s.id)
                thumbnailLoaders.removeValue(forKey: s.id)
                return true
            }
            return false
        }
        schedulePersist()
    }

    private func trim() {
        let limit = AppSettings.trayMaxItems
        guard items.count > limit else { return }
        let removed = items.dropFirst(limit)
        for item in removed {
            stopWatching(id: item.id)
            thumbnailLoaders.removeValue(forKey: item.id)
        }
        items = Array(items.prefix(limit))
        schedulePersist()
    }

    // MARK: Thumbnail Cache

    func thumbnailLoader(for shot: TrayScreenshot) -> ThumbnailLoader {
        if let loader = thumbnailLoaders[shot.id] { return loader }
        // Defensive lazy path for data created by future import/migration code.
        return prepareThumbnail(for: shot)
    }

    @discardableResult
    private func prepareThumbnail(for shot: TrayScreenshot) -> ThumbnailLoader {
        let loader = ThumbnailLoader()
        thumbnailLoaders[shot.id] = loader
        loader.load(imageURL: shot.url)
        return loader
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
                return PersistedTrayItem(kind: .color, hex: c.hex, path: nil, text: nil)
            case .screenshot(let s):
                return PersistedTrayItem(kind: .screenshot, hex: nil, path: s.url.path, text: nil)
            case .text(let t):
                return PersistedTrayItem(kind: .text, hex: nil, path: nil, text: t.text)
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

        // Screenshots live in ~/Downloads, a TCC-protected folder. Touching
        // them (existence check, thumbnail decode, file watch) before the
        // save-folder permission is granted fires the "Downloads" prompt — and
        // at launch that beats the onboarding wizard to the screen. While the
        // wizard still has to run (first launch, or permissions were reset),
        // restore screenshots optimistically without any file access; the
        // post-onboarding relaunch loads them normally.
        let deferScreenshotFiles = AppSettings.onboardingPending

        let restored: [TrayItem] = decoded.compactMap { p in
            switch p.kind {
            case .color:
                guard let hex = p.hex, let color = NSColor(hexString: hex) else { return nil }
                return .color(TrayColor(color: color, hex: hex))
            case .screenshot:
                guard let path = p.path else { return nil }
                let url = URL(fileURLWithPath: path)
                if deferScreenshotFiles { return .screenshot(TrayScreenshot(url: url)) }
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                return .screenshot(TrayScreenshot(url: url))
            case .text:
                guard let text = p.text, !text.isEmpty else { return nil }
                return .text(TrayText(text: text))
            }
        }
        items = restored
        guard !deferScreenshotFiles else { return }
        for case .screenshot(let shot) in items {
            prepareThumbnail(for: shot)
            startWatching(shot)
        }
    }


}
