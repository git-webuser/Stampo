import AppKit
import Combine

// MARK: - ThumbnailLoader

@MainActor
final class ThumbnailLoader: ObservableObject {
    @Published var image: NSImage?

    private var loadedURL: URL?
    private var loadTask: Task<Void, Never>?

    deinit { loadTask?.cancel() }

    func load(imageURL: URL, maxPixelSize: CGFloat = 200) {
        guard loadedURL != imageURL else { return }
        image = nil
        loadedURL = imageURL
        loadTask?.cancel()
        let url = imageURL

        loadTask = Task { @MainActor in
            let saveDir = AppSettings.saveDirectoryURL
            let hasBookmark = UserDefaults.standard.data(
                forKey: AppSettings.Keys.saveDirectoryBookmark) != nil
            let result: NSImage? = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    let accessing = hasBookmark && saveDir.startAccessingSecurityScopedResource()
                    defer { if accessing { saveDir.stopAccessingSecurityScopedResource() } }
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
