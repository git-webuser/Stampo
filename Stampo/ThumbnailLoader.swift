import AppKit
import QuickLookThumbnailing

// MARK: - ThumbnailLoader

/// Asynchronous preview for an arbitrary file, backed by Quick Look.
///
/// Quick Look rather than a private CGImageSource decode: the archive holds any
/// file the user drops on it, and the system already knows how to preview PDFs,
/// videos, Pages documents and anything else with a QL generator — an image
/// decoder would flatten all of those to a generic document icon. Requests ask
/// for `.thumbnail` (real content) and fall back to `.icon` (the document icon,
/// badged with content where the type provides one) for files nothing can
/// preview. `maxPixelSize` is the longest edge in pixels; Quick Look aspect-fits
/// into it and never upscales past the file's own resolution.
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

    /// Best available representation, content first. The two types are asked
    /// for separately (rather than as one `[.thumbnail, .icon]` request) so a
    /// file Quick Look can render never settles for its icon.
    private static func generate(for url: URL, maxPixelSize: CGFloat) async -> NSImage? {
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
}
