import AppKit

// MARK: - ThumbnailLoader

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
            let result: NSImage? = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    guard
                        let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                        let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize)
                        ] as CFDictionary)
                    else { return nil }
                    return NSImage(cgImage: cg, size: .zero)
                }
            }.value

            guard !Task.isCancelled, self.loadedURL == url else { return }
            image = result
        }
    }
}
