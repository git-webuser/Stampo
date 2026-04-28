import Foundation

// MARK: - ScreenshotFileStore

/// Generates filenames and moves temp captures to the final save directory.
final class ScreenshotFileStore {
    private let fm = FileManager.default

    /// Moves `tmpURL` to the user's configured save directory.
    /// Returns the final URL on success; throws on failure.
    func moveToFinalDestination(from tmpURL: URL) throws -> URL {
        try AppSettings.withSaveDirectoryAccess { outputDir in
            let dest = uniqueDestURL(in: outputDir, filename: makeFilename())
            try fm.moveItem(at: tmpURL, to: dest)
            return dest
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
