import AppKit

// MARK: - ScreenshotFileStore

/// Generates filenames and moves temp captures to the final save directory.
final class ScreenshotFileStore {
    private let fm = FileManager.default

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

    /// Encodes a bitmap into a throwaway file for handing to another app (the
    /// editor's share sheet). Sharing a file rather than an in-memory image
    /// keeps a real name and extension all the way into Mail, AirDrop and
    /// Finder. The export folder is recreated per call, so at most one stale
    /// export survives in the temp directory.
    func writeTemporaryExport(_ rep: NSBitmapImageRep, named name: String) throws -> URL {
        let format = AppSettings.fileFormat
        let (fileType, properties) = Self.encoding(for: format)
        guard let data = rep.representation(using: fileType, properties: properties) else {
            throw SaveError.encodingFailed
        }
        let dir = fm.temporaryDirectory.appendingPathComponent("Share", isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
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
