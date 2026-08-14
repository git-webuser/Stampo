import AppKit
import UniformTypeIdentifiers

/// The image formats the editor can write. Thin wrapper over the format
/// strings `AppSettings.fileFormat` and `ScreenshotFileStore` already speak —
/// the encoding table stays in one place, this only adds the type and label a
/// save panel needs.
nonisolated enum EditorExportFormat: String, CaseIterable, Sendable {
    case png
    case jpg
    case tiff

    /// The setting's value, or PNG when it names a format the editor can't
    /// write (nothing does today, but the setting is a free-form string).
    static func fromSettings() -> EditorExportFormat {
        EditorExportFormat(rawValue: AppSettings.fileFormat) ?? .png
    }

    var contentType: UTType {
        switch self {
        case .png:  return .png
        case .jpg:  return .jpeg
        case .tiff: return .tiff
        }
    }

    /// Shown in the save panel's format popup. Names of formats, not prose —
    /// they read the same in every language.
    var title: String {
        switch self {
        case .png:  return "PNG"
        case .jpg:  return "JPEG"
        case .tiff: return "TIFF"
        }
    }

    var fileExtension: String { ScreenshotFileStore.fileExtension(for: rawValue) }

    var encoding: (NSBitmapImageRep.FileType, [NSBitmapImageRep.PropertyKey: Any]) {
        ScreenshotFileStore.encoding(for: rawValue)
    }
}
