import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Archive Item

enum ArchiveItem: Identifiable, Equatable {
    case color(ArchiveColor)
    case screenshot(ArchiveScreenshot)
    case text(ArchiveText)
    case stack(ArchiveStack)

    var id: UUID {
        switch self {
        case .color(let c):      return c.id
        case .screenshot(let s): return s.id
        case .text(let t):       return t.id
        case .stack(let s):      return s.id
        }
    }
}

struct ArchiveColor: Identifiable, Equatable {
    let id = UUID()
    let color: NSColor
    let hex: String
}

struct ArchiveScreenshot: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

/// A pile of files the user dropped onto the archive. Files are
/// grouped by their source folder: the archive keeps one stack per parent folder,
/// so dropping from two folders yields two stacks. Consecutive drops from the
/// same folder accumulate (deduplicated by standardized URL), and dragging a
/// stack out carries every member at once. Members are references to the
/// original files, never copies.
struct ArchiveStack: Identifiable, Equatable {
    let id = UUID()
    var urls: [URL]

    /// The source folder shared by every member. All members are grouped by
    /// parent folder, so this is well-defined; nil only for an empty stack.
    /// Derived (not stored): the members already carry standardized paths, so
    /// this matches the grouping key in `groupedByFolder` exactly.
    var folder: URL? { urls.first?.deletingLastPathComponent() }

    /// Groups dropped URLs by parent folder, preserving first-seen folder order
    /// and deduplicating within the whole batch. One drop spanning several
    /// folders therefore fans out into several stacks.
    static func groupedByFolder(_ urls: [URL]) -> [(folder: URL, urls: [URL])] {
        var seen = Set<URL>()
        var order: [URL] = []
        var buckets: [URL: [URL]] = [:]
        for url in urls.map(\.standardizedFileURL) where seen.insert(url).inserted {
            let folder = url.deletingLastPathComponent()
            if buckets[folder] == nil { order.append(folder) }
            buckets[folder, default: []].append(url)
        }
        return order.map { (folder: $0, urls: buckets[$0]!) }
    }

    /// Pure accumulate half of NotchArchiveModel.add(droppedFiles:): standardizes
    /// URLs, dedupes within the batch and against the existing stack. Returns
    /// the resulting stack (the existing one keeps its identity) and the URLs
    /// that are actually new — the ones that need file watchers.
    static func merging(_ existing: ArchiveStack?, droppedFiles urls: [URL]) -> (stack: ArchiveStack, fresh: [URL]) {
        var seen = Set<URL>()
        let incoming = urls.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
        guard var stack = existing else {
            return (ArchiveStack(urls: incoming), incoming)
        }
        let known = Set(stack.urls)
        let fresh = incoming.filter { !known.contains($0) }
        stack.urls.append(contentsOf: fresh)
        return (stack, fresh)
    }

    /// Pure removal half of NotchArchiveModel.removeStackMember: nil when the
    /// last member leaves (the stack disappears from the archive).
    func removingMember(_ url: URL) -> ArchiveStack? {
        let target = url.standardizedFileURL
        var copy = self
        copy.urls.removeAll { $0 == target }
        return copy.urls.isEmpty ? nil : copy
    }
}

/// A plain-text entity captured via OCR or Scan Code.
struct ArchiveText: Identifiable, Equatable {
    let id = UUID()
    let text: String

    /// True when this came from a barcode or QR symbol rather than from
    /// recognized prose. A payload is a value — a URL, a Wi-Fi config, a
    /// tracking number — so anything that treats entries as language has to
    /// leave it alone. Translation is the first such thing; there will be
    /// others.
    var isCodePayload: Bool = false

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

    /// Reads a colour written in this notation. The mirror of `convert`, and
    /// the reason it lives beside it: a notation the app prints and cannot read
    /// back is a field the user can only look at.
    func parse(_ text: String) -> NSColor? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch self {
        case .hex:  return NSColor(hexString: trimmed)
        case .rgb:  return NSColor(rgbString: trimmed)
        case .hsl:  return NSColor(hslString: trimmed)
        case .hsb:  return NSColor(hsbString: trimmed)
        case .cmyk: return NSColor(cmykString: trimmed)
        }
    }

    /// The colour a piece of text describes, read in the user's own notation
    /// first and then in every other one.
    ///
    /// Trying the rest matters because text arrives from the clipboard as often
    /// as from the keyboard: a `#3A7BD5` pasted from a brand sheet should work
    /// while the panel is set to RGB. The preferred notation goes first because
    /// HSL and HSB are written identically — "30° 33% 89%" is a valid pair of
    /// different colours, and the setting is the only thing that can say which.
    static func color(from text: String, preferring format: ColorSchemeType) -> NSColor? {
        if let parsed = format.parse(text) { return parsed }
        return allCases.first { $0 != format }.flatMap { _ in
            allCases.lazy.compactMap { $0 == format ? nil : $0.parse(text) }.first
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

// MARK: - File kinds

/// What the archive can tell about a dropped file without opening it.
enum ArchiveFileKind {
    /// True for a still image the editor can load. Decided by the file's UTI,
    /// not its extension: a `.icon` package conforms to nothing image-like, and
    /// an image saved with the wrong extension is still recognized. Multi-frame
    /// formats (GIF) are excluded — the editor would flatten them to frame one
    /// and quietly discard the animation on save.
    static func isEditableImage(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
              type.conforms(to: .image),
              !type.conforms(to: .gif)
        else { return false }
        // A package can conform to .image in principle; the editor needs a file.
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
    }
}

// MARK: - Archive Payload

/// One archive entry flattened into something the pasteboard and the share sheet
/// both understand. Files stay files (so a paste in Finder reproduces them and
/// AirDrop carries the real bytes); colors and text become their string form.
enum ArchivePayloadItem: Equatable {
    case file(URL)
    case string(String)
}

extension Array where Element == ArchivePayloadItem {
    /// Boxed for `NSPasteboard.writeObjects` / `NSSharingServicePicker(items:)`,
    /// both of which take Objective-C objects rather than Swift values.
    var objects: [Any] {
        map {
            switch $0 {
            case .file(let url):    return url as NSURL
            case .string(let text): return text as NSString
            }
        }
    }
}

// MARK: - Archive Persistence (Codable)

private struct PersistedArchiveItem: Codable {
    enum Kind: String, Codable { case color, screenshot, text, stack }
    let kind: Kind
    let hex:  String?    // color items
    let path: String?    // screenshot items
    let text: String?    // text items
    let paths: [String]? // stack items (absent in pre-stack data)
    /// Text items only, and absent in data written before code payloads were
    /// distinguished — those decode as prose, which is what they were treated
    /// as at the time.
    let isCode: Bool?
}

// MARK: - NotchArchiveModel

@Observable final class NotchArchiveModel {
    private(set) var items: [ArchiveItem] = []

    private var persistWorkItem: DispatchWorkItem?
    @ObservationIgnored private var fileWatchers: [UUID: DispatchSourceFileSystemObject] = [:]
    /// Per-member watchers of the (single) stack item, keyed by file path —
    /// unlike screenshots, one stack item watches N files.
    @ObservationIgnored private var stackWatchers: [String: DispatchSourceFileSystemObject] = [:]
    /// Preview loaders for stack members, keyed by file path.
    @ObservationIgnored private var stackLoaders: [String: ThumbnailLoader] = [:]
    /// Thumbnail loaders outlive individual SwiftUI cells and hosting views.
    /// Without this cache, recreating the panel briefly replaces every preview
    /// with the placeholder while the same files are decoded again.
    @ObservationIgnored private var thumbnailLoaders: [UUID: ThumbnailLoader] = [:]
    /// Non-nil while a restore ran with file access deferred behind the
    /// onboarding wizard; fires completeDeferredRestore on wizard close.
    @ObservationIgnored private var deferredRestoreObserver: NSObjectProtocol?

    private func schedulePersist() {
        persistWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.persistIfNeeded() }
        persistWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    init() {
        restoreIfNeeded()
        #if DEBUG
        if DemoArchive.isEnabled {
            items.removeAll()
            DemoArchive.populate(self)
        }
        #endif
    }

    isolated deinit {
        fileWatchers.values.forEach { $0.cancel() }
        stackWatchers.values.forEach { $0.cancel() }
        if let obs = deferredRestoreObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    var colors: [ArchiveColor] {
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
        items.insert(.color(ArchiveColor(color: c, hex: hex)), at: 0)
        trim()
        schedulePersist()
    }

    func add(text: String, isCodePayload: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Deduplicated on the string alone: the same payload arriving once as a
        // scanned symbol and once as recognized prose is still one entry, and
        // the fresher origin is the one worth keeping.
        items.removeAll {
            if case .text(let existing) = $0 { return existing.text == trimmed }
            return false
        }
        items.insert(.text(ArchiveText(text: trimmed, isCodePayload: isCodePayload)), at: 0)
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
        let shot = ArchiveScreenshot(url: url)
        prepareThumbnail(for: shot)
        items.insert(.screenshot(shot), at: 0)
        startWatching(shot)
        trim()
        schedulePersist()
    }

    // MARK: Stack (dropped files)

    /// Every stack item currently in the archive (one per source folder).
    var stacks: [ArchiveStack] {
        items.compactMap { if case .stack(let s) = $0 { return s } else { return nil } }
    }

    /// Ingest files dropped onto the archive. Files are grouped by parent folder:
    /// each group accumulates into its folder's existing stack (deduplicated by
    /// standardized URL) or creates a new one. Every touched stack moves to the
    /// front so the user sees where the drop landed.
    func add(droppedFiles urls: [URL]) {
        guard !urls.isEmpty else { return }
        var didChange = false

        for group in ArchiveStack.groupedByFolder(urls) {
            let existingIdx = items.firstIndex {
                if case .stack(let s) = $0 { return s.folder == group.folder } else { return false }
            }
            let existing: ArchiveStack? = existingIdx.flatMap {
                if case .stack(let s) = items[$0] { return s } else { return nil }
            }

            let (stack, fresh) = ArchiveStack.merging(existing, droppedFiles: group.urls)
            // A pure re-drop of files already in this folder's stack: nothing
            // new to show, don't even reorder.
            if existing != nil && fresh.isEmpty { continue }

            if let existingIdx { items.remove(at: existingIdx) }
            items.insert(.stack(stack), at: 0)
            for url in fresh { startWatchingStackMember(url) }
            if existing == nil { trim() }
            didChange = true
        }

        if didChange { schedulePersist() }
    }

    /// Drop a single member from the stack (file deleted on disk, or removed
    /// via UI). An emptied stack disappears from the archive entirely.
    func removeStackMember(url: URL) {
        let target = url.standardizedFileURL
        // A path has exactly one parent folder, so it belongs to exactly one
        // stack — find the stack that actually contains it, not merely the
        // first stack in the archive.
        guard let idx = items.firstIndex(where: {
                  if case .stack(let s) = $0 { return s.urls.contains(target) } else { return false }
              }),
              case .stack(let stack) = items[idx]
        else { return }

        stopWatchingStackMember(target)
        if let updated = stack.removingMember(target) {
            items[idx] = .stack(updated)
        } else {
            items.remove(at: idx)
        }
        schedulePersist()
    }

    func remove(id: UUID) {
        if let item = items.first(where: { $0.id == id }) {
            releaseResources(for: item)
        }
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

    /// The given entries, in display order, flattened for the pasteboard
    /// and the share sheet. A stack contributes each of its members. Pure and
    /// static so Copy and Share can never disagree about what was picked.
    /// `colorScheme` picks the notation for color entries — the one currently
    /// selected in the archive header, so the copied text matches what the
    /// cells display.
    static func payload(for items: [ArchiveItem], colorScheme: ColorSchemeType) -> [ArchivePayloadItem] {
        items.flatMap { item -> [ArchivePayloadItem] in
            switch item {
            case .color(let c):      return [.string(colorScheme.convert(c.color))]
            case .text(let t):       return [.string(t.text)]
            case .screenshot(let s): return [.file(s.url)]
            case .stack(let stack):  return stack.urls.map { .file($0) }
            }
        }
    }

    /// The same entries flattened for a *drag* instead of for the pasteboard
    /// and the share sheet.
    ///
    /// Identical fan-out — one item per colour, snippet and capture, one per
    /// member of a stack — but each kind is encoded the way its own cell's drag
    /// already encodes it: a capture in the format the user picked rather than
    /// the one on disk, a colour as a swatch *and* as text so a colour well and
    /// a text editor both accept the drop. None of which the share sheet wants,
    /// which is why this is a second function and not a flag on `payload`.
    static func dragPayload(for items: [ArchiveItem],
                            colorScheme: ColorSchemeType,
                            format: EditorExportFormat = .fromSettings()) -> [NSPasteboardWriting] {
        items.flatMap { item -> [NSPasteboardWriting] in
            switch item {
            case .color(let c):
                return ArchiveDragPayload.color(c.color, formatted: colorScheme.convert(c.color))
            case .text(let t):       return ArchiveDragPayload.text(t.text)
            case .screenshot(let s): return ArchiveDragPayload.capture(s.url, as: format)
            case .stack(let stack):  return ArchiveDragPayload.files(stack.urls)
            }
        }
    }

    private func trim() {
        let limit = AppSettings.trayMaxItems
        guard items.count > limit else { return }
        let removed = items.dropFirst(limit)
        for item in removed {
            releaseResources(for: item)
        }
        items = Array(items.prefix(limit))
        schedulePersist()
    }

    /// Watcher/loader teardown shared by remove(id:) and trim(). A stack owns
    /// per-member resources; every other kind owns at most one of each.
    private func releaseResources(for item: ArchiveItem) {
        if case .stack(let stack) = item {
            for url in stack.urls { stopWatchingStackMember(url) }
        } else {
            stopWatching(id: item.id)
            thumbnailLoaders.removeValue(forKey: item.id)
        }
    }

    // MARK: Thumbnail Cache

    func thumbnailLoader(for shot: ArchiveScreenshot) -> ThumbnailLoader {
        if let loader = thumbnailLoaders[shot.id] { return loader }
        // Defensive lazy path for data created by future import/migration code.
        return prepareThumbnail(for: shot)
    }

    @discardableResult
    private func prepareThumbnail(for shot: ArchiveScreenshot) -> ThumbnailLoader {
        let loader = ThumbnailLoader()
        thumbnailLoaders[shot.id] = loader
        loader.load(imageURL: shot.url)
        return loader
    }

    /// Preview loader for a stack member of any file type — Quick Look renders
    /// what it can and falls back to the file's icon, so no type is filtered
    /// out up front. Lazy: only the members the fan actually shows are loaded.
    func stackThumbnailLoader(for url: URL) -> ThumbnailLoader {
        if let loader = stackLoaders[url.path] { return loader }
        let loader = ThumbnailLoader()
        stackLoaders[url.path] = loader
        loader.load(imageURL: url)
        return loader
    }

    // MARK: File Watching

    private func startWatching(_ shot: ArchiveScreenshot) {
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

    private func startWatchingStackMember(_ url: URL) {
        let path = url.path
        guard stackWatchers[path] == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            if !FileManager.default.fileExists(atPath: path) {
                self?.removeStackMember(url: url)
            }
        }
        source.setCancelHandler { close(fd) }

        stackWatchers[path] = source
        source.resume()
    }

    private func stopWatchingStackMember(_ url: URL) {
        stackWatchers.removeValue(forKey: url.path)?.cancel()
        stackLoaders.removeValue(forKey: url.path)
    }

    // MARK: Persistence

    private func persistIfNeeded() {
        #if DEBUG
        // Demo mode owns the archive for this run only — writing its fake
        // entries out would overwrite whatever the real archive holds.
        if DemoArchive.isEnabled { return }
        #endif
        guard AppSettings.persistTray else { return }
        if let data = Self.encodePersistedItems(items) {
            UserDefaults.standard.set(data, forKey: AppSettings.Keys.trayPersistedData)
        }
    }

    /// Pure encode half of archive persistence. Internal so tests can round-trip
    /// items without UserDefaults.
    static func encodePersistedItems(_ items: [ArchiveItem]) -> Data? {
        let encoded: [PersistedArchiveItem] = items.map {
            switch $0 {
            case .color(let c):
                return PersistedArchiveItem(kind: .color, hex: c.hex, path: nil, text: nil, paths: nil, isCode: nil)
            case .screenshot(let s):
                return PersistedArchiveItem(kind: .screenshot, hex: nil, path: s.url.path, text: nil, paths: nil, isCode: nil)
            case .text(let t):
                return PersistedArchiveItem(kind: .text, hex: nil, path: nil, text: t.text, paths: nil,
                                            isCode: t.isCodePayload ? true : nil)
            case .stack(let s):
                return PersistedArchiveItem(kind: .stack, hex: nil, path: nil, text: nil, paths: s.urls.map(\.path), isCode: nil)
            }
        }
        return try? JSONEncoder().encode(encoded)
    }

    /// Pure decode half of archive persistence. With `deferFileChecks` the file
    /// system is never touched (the TCC-deferred restore path); otherwise
    /// entries whose files vanished are dropped, including individual stack
    /// members (an emptied stack is dropped whole). `fileExists` is
    /// injectable for tests.
    static func decodePersistedItems(
        _ data: Data,
        deferFileChecks: Bool,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [ArchiveItem] {
        guard let decoded = try? JSONDecoder().decode([PersistedArchiveItem].self, from: data)
        else { return [] }

        return decoded.compactMap { p in
            switch p.kind {
            case .color:
                guard let hex = p.hex, let color = NSColor(hexString: hex) else { return nil }
                return .color(ArchiveColor(color: color, hex: hex))
            case .screenshot:
                guard let path = p.path else { return nil }
                guard deferFileChecks || fileExists(path) else { return nil }
                return .screenshot(ArchiveScreenshot(url: URL(fileURLWithPath: path)))
            case .text:
                guard let text = p.text, !text.isEmpty else { return nil }
                return .text(ArchiveText(text: text, isCodePayload: p.isCode ?? false))
            case .stack:
                guard let paths = p.paths, !paths.isEmpty else { return nil }
                let kept = deferFileChecks ? paths : paths.filter(fileExists)
                guard !kept.isEmpty else { return nil }
                return .stack(ArchiveStack(urls: kept.map { URL(fileURLWithPath: $0) }))
            }
        }
    }

    private func restoreIfNeeded() {
        guard AppSettings.persistTray,
              let data = UserDefaults.standard.data(forKey: AppSettings.Keys.trayPersistedData)
        else { return }

        // The default save folder (~/Pictures/Stampo) is outside the TCC set, but
        // a user may have pointed the save folder at a protected location
        // (Downloads/Desktop/Documents) via Settings — and stack members are
        // arbitrary user paths, so they live in TCC folders routinely. Touching
        // those files (existence check, thumbnail decode, file watch) before the
        // wizard has run could fire a TCC prompt that beats the onboarding
        // wizard to the screen. While the wizard still has to run (first launch,
        // or the system permissions were reset), restore file-backed items
        // optimistically without any file access; the post-onboarding relaunch
        // loads them normally.
        let deferScreenshotFiles = AppSettings.onboardingPending

        items = Self.decodePersistedItems(data, deferFileChecks: deferScreenshotFiles)
        guard !deferScreenshotFiles else {
            // The wizard doesn't always end in a relaunch (e.g. only Input
            // Monitoring was re-granted): complete the deferred file phase —
            // existence filter, thumbnails, watchers — when its window closes,
            // or this session would keep bare, unwatched entries forever.
            deferredRestoreObserver = NotificationCenter.default.addObserver(
                forName: .onboardingWindowClosed,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.completeDeferredRestore() }
            }
            return
        }
        attachFileResources()
    }

    /// The file-access half of a restore: drop entries whose files vanished,
    /// then decode thumbnails and start watching the survivors.
    private func attachFileResources() {
        items.removeAll {
            if case .screenshot(let shot) = $0 {
                return !FileManager.default.fileExists(atPath: shot.url.path)
            }
            return false
        }
        for case .screenshot(let shot) in items {
            prepareThumbnail(for: shot)
            startWatching(shot)
        }
        // Drop members whose files vanished across every stack, then watch the
        // survivors. Snapshot first: removeStackMember mutates `items`, and an
        // emptied stack drops out entirely.
        let allMembers = stacks.flatMap(\.urls)
        for url in allMembers where !FileManager.default.fileExists(atPath: url.path) {
            removeStackMember(url: url)
        }
        for url in stacks.flatMap(\.urls) { startWatchingStackMember(url) }
    }

    private func completeDeferredRestore() {
        if let obs = deferredRestoreObserver {
            NotificationCenter.default.removeObserver(obs)
            deferredRestoreObserver = nil
        }
        attachFileResources()
    }
}

// MARK: - PresentationColorShelf

/// The archive is the app's one list of colours, so it is also the editor's.
/// A colour saved from the decor inspector shows up in the panel and is
/// removed there, like any other entry — no second palette to keep in sync.
extension NotchArchiveModel: PresentationColorShelf {
    var shelfColors: [Presentation.Color] {
        colors.map { Presentation.Color($0.color) }
    }

    func addShelfColor(_ color: Presentation.Color) {
        add(color: color.nsColor)
    }
}
