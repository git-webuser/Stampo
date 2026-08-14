import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Stampo

/// Save As offers a format; the encoding behind it has to stay the same one
/// the rest of the app uses, or a file saved as JPEG through the panel would
/// differ from the same file saved as JPEG by a capture.
@Suite struct EditorExportFormatTests {

    @Test func extensionsAndTypesLineUp() {
        #expect(EditorExportFormat.png.fileExtension == "png")
        #expect(EditorExportFormat.jpg.fileExtension == "jpg")
        #expect(EditorExportFormat.tiff.fileExtension == "tiff")
        #expect(EditorExportFormat.png.contentType == .png)
        #expect(EditorExportFormat.jpg.contentType == .jpeg)
        #expect(EditorExportFormat.tiff.contentType == .tiff)
    }

    /// Raw values are the format strings `AppSettings.fileFormat` stores, so
    /// the settings value maps onto a case without a translation table.
    @Test func rawValuesMatchTheSettingsVocabulary() {
        for format in EditorExportFormat.allCases {
            let (fileType, _) = ScreenshotFileStore.encoding(for: format.rawValue)
            let (expected, _) = format.encoding
            #expect(fileType == expected)
        }
        #expect(EditorExportFormat(rawValue: "png") == .png)
        #expect(EditorExportFormat(rawValue: "jpg") == .jpg)
        #expect(EditorExportFormat(rawValue: "tiff") == .tiff)
        #expect(EditorExportFormat(rawValue: "webp") == nil)
    }

    @Test func encodingMatchesTheFormat() {
        #expect(EditorExportFormat.png.encoding.0 == .png)
        #expect(EditorExportFormat.jpg.encoding.0 == .jpeg)
        #expect(EditorExportFormat.tiff.encoding.0 == .tiff)
    }

    /// Round-trip through the encoded-data writer: the bytes on disk must
    /// actually be the chosen format, not PNG with a renamed extension.
    @Test func writeEncodedDataProducesTheChosenFormat() throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let store = ScreenshotFileStore()
        for format in EditorExportFormat.allCases {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("export-test-\(UUID().uuidString)")
                .appendingPathExtension(format.fileExtension)
            defer { try? FileManager.default.removeItem(at: url) }

            let (fileType, properties) = ScreenshotFileStore.encoding(for: format.rawValue)
            let data = try #require(rep.representation(using: fileType, properties: properties))
            try store.writeEncodedData(data, to: url)
            #expect(try Data(contentsOf: url) == data)
            let written = try #require(url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            #expect(written.conforms(to: format.contentType))
        }
    }
}

// MARK: - Editable-image predicate

/// "Edit" only shows up for files the editor can actually open — the archive
/// holds whatever the user dropped, including packages and documents.
@Suite struct ArchiveFileKindTests {

    private func write(_ data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kind-test-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try data.write(to: url)
        return url
    }

    private func pngData() throws -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.systemIndigo.setFill(); rect.fill(); return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func imagesAreEditable() throws {
        let png = try write(try pngData(), ext: "png")
        defer { try? FileManager.default.removeItem(at: png) }
        #expect(ArchiveFileKind.isEditableImage(png))
    }

    @Test func documentsAndUnknownFilesAreNot() throws {
        let pdf = try write(Data("%PDF-1.4\n%%EOF\n".utf8), ext: "pdf")
        let text = try write(Data("hello".utf8), ext: "txt")
        defer {
            try? FileManager.default.removeItem(at: pdf)
            try? FileManager.default.removeItem(at: text)
        }
        #expect(!ArchiveFileKind.isEditableImage(pdf))
        #expect(!ArchiveFileKind.isEditableImage(text))
    }

    /// The case that started all of this: `.icon` is a directory, and the
    /// editor needs a file it can hand to CGImageSource.
    @Test func packagesAreNotEditable() throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("kind-test-\(UUID().uuidString).icon", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        #expect(!ArchiveFileKind.isEditableImage(package))
    }

    /// Opening a GIF would flatten it to its first frame on save — better to
    /// not offer the action than to silently destroy the animation.
    @Test func animatedGIFsAreLeftAlone() throws {
        // 1×1 transparent GIF89a.
        let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
        let url = try write(gif, ext: "gif")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!ArchiveFileKind.isEditableImage(url))
    }
}
