import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

// MARK: - ThumbnailLoader

/// Asynchronous preview for an arbitrary file: ImageIO for still images, Quick
/// Look for everything else.
///
/// Quick Look rather than a private decode for the general case: the archive
/// holds any file the user drops on it, and the system already knows how to
/// preview PDFs, videos, Pages documents and anything else with a QL generator
/// — an image decoder would flatten all of those to a generic document icon.
/// Requests ask for `.thumbnail` (real content) and fall back to `.icon` (the
/// document icon, badged with content where the type provides one) for files
/// nothing can preview. Images take the ImageIO path because Quick Look caps
/// how large a thumbnail it will render; see `decodeImage(at:maxPixelSize:)`.
/// `maxPixelSize` is the longest edge in pixels; either path aspect-fits into
/// it and never upscales past the file's own resolution.
@MainActor @Observable
final class ThumbnailLoader {
    var image: NSImage?

    private var loadedURL: URL?
    @ObservationIgnored nonisolated(unsafe) private var loadTask: Task<Void, Never>?

    deinit { loadTask?.cancel() }

    func load(imageURL: URL, maxPixelSize: CGFloat = 200) {
        guard loadedURL != imageURL else { return }
        image = nil
        loadedURL = imageURL
        loadTask?.cancel()
        let url = imageURL

        loadTask = Task { @MainActor in
            let result = await Self.generate(for: url, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled, self.loadedURL == url else { return }
            image = result
        }
    }

    /// Best available representation, content first. Still images are decoded
    /// directly; everything else goes to Quick Look, which is asked for
    /// `.thumbnail` and `.icon` separately (rather than as one
    /// `[.thumbnail, .icon]` request) so a file Quick Look can render never
    /// settles for its icon.
    private static func generate(for url: URL, maxPixelSize: CGFloat) async -> NSImage? {
        if let decoded = await decodeImage(at: url, maxPixelSize: maxPixelSize) {
            return decoded
        }
        for type in [QLThumbnailGenerator.Request.RepresentationTypes.thumbnail, .icon] {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: maxPixelSize, height: maxPixelSize),
                scale: 1,
                representationTypes: type
            )
            let representation = await withTaskCancellationHandler {
                try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            } onCancel: {
                QLThumbnailGenerator.shared.cancel(request)
            }
            if let representation {
                return NSImage(cgImage: representation.cgImage, size: .zero)
            }
            if Task.isCancelled { return nil }
        }
        return nil
    }

    /// ImageIO decode for files that are plain images, nil for everything else
    /// (a PDF, a video, a package — those are Quick Look's job).
    ///
    /// Quick Look is the better source for arbitrary files, but it refuses a
    /// `.thumbnail` request once the result would pass roughly three
    /// megapixels: a 2560×1596 screenshot renders at 2100 pt and fails at 2400,
    /// after which the loader has nothing left to offer but the generic PNG
    /// document icon. Pinned screenshots ask for the whole screen in backing
    /// pixels, so every capture past that ceiling used to pin as a document
    /// icon. ImageIO has no such ceiling, reads the file itself, and — like
    /// Quick Look — aspect-fits into `maxPixelSize` without ever upscaling.
    private static func decodeImage(at url: URL, maxPixelSize: CGFloat) async -> NSImage? {
        await withCheckedContinuation { continuation in
            // Off the main actor: a full-resolution decode of a 5K screenshot
            // takes long enough to drop frames in the panel.
            DispatchQueue.global(qos: .userInitiated).async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let uti = CGImageSourceGetType(source) as? String,
                      let type = UTType(uti), type.conforms(to: .image)
                else { return continuation.resume(returning: nil) }

                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1),
                ]
                let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                continuation.resume(returning: cgImage.map { NSImage(cgImage: $0, size: .zero) })
            }
        }
    }
}
