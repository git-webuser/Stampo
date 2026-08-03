import AppKit

// MARK: - ScreenshotFileStore

/// Generates filenames and moves temp captures to the final save directory.
final class ScreenshotFileStore {
    private let fm = FileManager.default

    /// Parent of the staging directories the throwaway exports live under.
    /// Overridable so a test can work somewhere of its own: the sweeping rules
    /// below are about deleting other people's files, and two tests sharing the
    /// app's real temp directory would be deleting each other's.
    private let stagingRoot: URL

    init(stagingRoot: URL? = nil) {
        self.stagingRoot = stagingRoot ?? FileManager.default.temporaryDirectory
    }

    enum SaveError: Error {
        case encodingFailed
    }

    /// Moves `tmpURL` to the user's configured save directory.
    /// Returns the final URL on success; throws on failure.
    func moveToFinalDestination(from tmpURL: URL) throws -> URL {
        try AppSettings.withSaveDirectoryAccess { outputDir in
            try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
            let dest = uniqueDestURL(in: outputDir, filename: makeFilename())
            try fm.moveItem(at: tmpURL, to: dest)
            return dest
        }
    }

    /// Encodes an in-memory bitmap (e.g. an edited screenshot) into the save
    /// directory as a NEW file with a standard uniqued name, honoring the
    /// configured file format. Returns the written URL.
    func saveImage(_ rep: NSBitmapImageRep) throws -> URL {
        let (fileType, properties) = Self.encoding(for: AppSettings.fileFormat)
        guard let data = rep.representation(using: fileType, properties: properties) else {
            throw SaveError.encodingFailed
        }
        return try AppSettings.withSaveDirectoryAccess { outputDir in
            try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
            let dest = uniqueDestURL(in: outputDir, filename: makeFilename())
            try data.write(to: dest)
            return dest
        }
    }

    /// Writes a bitmap to a caller-chosen destination in a caller-chosen
    /// format — the Save As path. No uniquing and no save-directory scope: the
    /// save panel already picked the exact URL and granted access to it, and
    /// overwriting is the user's explicit choice there.
    func writeImage(_ rep: NSBitmapImageRep, to url: URL, format: String) throws {
        let (fileType, properties) = Self.encoding(for: format)
        guard let data = rep.representation(using: fileType, properties: properties) else {
            throw SaveError.encodingFailed
        }
        try data.write(to: url)
    }

    /// Encodes a bitmap into a throwaway file for handing to another app (the
    /// editor's share sheet). Sharing a file rather than an in-memory image
    /// keeps a real name and extension all the way into Mail, AirDrop and
    /// Finder.
    ///
    /// Every export gets its own directory so the filename can stay exactly
    /// the document's, with no uniquing suffix, and so a second share never
    /// pulls the file out from under the first — an AirDrop transfer or a Mail
    /// draft may still be reading it. Older exports are swept on the way in
    /// (see `TemporaryStaging`).
    func writeTemporaryExport(_ rep: NSBitmapImageRep, named name: String) throws -> URL {
        let format = AppSettings.fileFormat
        let (fileType, properties) = Self.encoding(for: format)
        guard let data = rep.representation(using: fileType, properties: properties) else {
            throw SaveError.encodingFailed
        }
        return try writeTemporaryExport(data, named: name, format: format)
    }

    /// The same throwaway file from bytes that are already encoded — the
    /// pasteboard path has them in hand and would otherwise encode twice.
    func writeTemporaryExport(_ data: Data, named name: String, format: String) throws -> URL {
        try write(data, named: name, format: format,
                  in: stagingRoot.appendingPathComponent("Share", isDirectory: true))
    }

    /// A throwaway for the *clipboard*, which is swept on a clock of its own.
    ///
    /// A capture whose format disagrees with the setting is re-encoded on its
    /// way to the pasteboard, and it is that copy — not the capture — that goes
    /// on beside the image data: a receiver preferring files (Finder, Mail)
    /// would otherwise take the original back in the old format and undo the
    /// exercise. But a clipboard is not a share sheet. Pasting an hour after
    /// copying is an ordinary way to use one, and staged with everything else
    /// the copy quietly stopped working a quarter of an hour in — the picture
    /// still pasted, the file behind it did not.
    ///
    /// The clipboard holds one thing at a time, and can only be pointing at the
    /// newest export — so that one is spared whatever its age and the rest go on
    /// the ordinary clock (`TemporaryStaging.Retention.byAgeSparingNewest`).
    /// Kept in a root of its own because a share sheet's file has no such
    /// guarantee: several of those can be live at once.
    func writeClipboardExport(_ data: Data, named name: String, format: String) throws -> URL {
        try write(data, named: name, format: format,
                  in: stagingRoot.appendingPathComponent("Clipboard", isDirectory: true),
                  retention: .byAgeSparingNewest)
    }

    private func write(_ data: Data,
                       named name: String,
                       format: String,
                       in root: URL,
                       retention: TemporaryStaging.Retention = .byAge) throws -> URL {
        let dir = try TemporaryStaging.makeDirectory(in: root, retention: retention)
        // A document whose name is empty (or all extension) would otherwise
        // produce a bare ".png" — invisible in Finder and useless in Mail.
        let base = name.isEmpty ? "Screenshot" : name
        let dest = dir.appendingPathComponent(base)
            .appendingPathExtension(Self.fileExtension(for: format))
        try data.write(to: dest)
        return dest
    }

    /// Maps the user-facing format string (png/jpg/tiff) onto bitmap encoding
    /// parameters. Pure — unit-testable.
    static func encoding(for format: String)
        -> (NSBitmapImageRep.FileType, [NSBitmapImageRep.PropertyKey: Any])
    {
        switch format {
        case "jpg":  return (.jpeg, [.compressionFactor: 0.9])
        case "tiff": return (.tiff, [:])
        default:     return (.png, [:])
        }
    }

    /// Filename extension for a format string, falling back to png in step
    /// with `encoding(for:)`.
    static func fileExtension(for format: String) -> String {
        switch format {
        case "jpg", "tiff": return format
        default:            return "png"
        }
    }

    // MARK: - Private

    private func makeFilename() -> String {
        AppSettings.resolveFilename(
            preset:  AppSettings.filenamePreset,
            date:    Date(),
            counter: AppSettings.nextCaptureCounter(),
            format:  AppSettings.fileFormat
        )
    }

    /// Appends " 2", " 3", etc. on filename collision.
    private func uniqueDestURL(in dir: URL, filename: String) -> URL {
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let ext  = URL(fileURLWithPath: filename).pathExtension
        let url  = dir.appendingPathComponent(filename)
        guard fm.fileExists(atPath: url.path) else { return url }
        for n in 2..<1000 {
            let candidate = dir.appendingPathComponent("\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        // Все 999 слотов заняты — возвращаем путь с уникальным суффиксом.
        // Старый fallback возвращал url, который уже существует, что роняло moveItem.
        let uid = UUID().uuidString.prefix(8)
        return dir.appendingPathComponent("\(base) \(uid).\(ext)")
    }
}
