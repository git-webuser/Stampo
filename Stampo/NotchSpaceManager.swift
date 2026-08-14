import Foundation
import AppKit
import OSLog

@MainActor
protocol PanelSpaceAdapter: AnyObject {
    var isAvailable: Bool { get }
    func attach(_ window: NSWindow)
    func detach(_ window: NSWindow)
    func tearDown()
}

/// Private CGS-backed placement. The wrapper is optional by design: symbols
/// can disappear between macOS releases, and panel presentation must survive
/// that as a supported AppKit fallback.
@MainActor
final class CGSSpaceAdapter: PanelSpaceAdapter {
    private let space: CGSSpace?

    init(symbolResolver: (any CGSSymbolResolver)? = nil) {
        if let symbolResolver {
            space = CGSSpace(level: Int(Int32.max), resolver: symbolResolver)
        } else {
            space = CGSSpace(level: Int(Int32.max))
        }
        if space == nil {
            Log.panel.warning("CGS Spaces symbols unavailable; using standard AppKit placement")
        }
    }

    var isAvailable: Bool { space != nil }

    func attach(_ window: NSWindow) {
        space?.windows = [window]
    }

    func detach(_ window: NSWindow) {
        guard var windows = space?.windows else { return }
        windows.remove(window)
        space?.windows = windows
    }

    func tearDown() {
        space?.windows = []
    }
}

/// Supported AppKit-only placement used when private CGS symbols are absent.
@MainActor
final class StandardSpaceAdapter: PanelSpaceAdapter {
    let isAvailable = true

    func attach(_ window: NSWindow) {
        window.collectionBehavior.formUnion([
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .moveToActiveSpace
        ])
    }

    func detach(_ window: NSWindow) {
        window.collectionBehavior.remove(.moveToActiveSpace)
    }

    func tearDown() {}
}

/// Owns the single dedicated CGS space the notch panel lives in, while
/// exposing one placement facade to the panel controller.
@MainActor
final class NotchSpaceManager {
    static let shared = NotchSpaceManager()
    let adapter: any PanelSpaceAdapter

    private init() {
        let cgs = CGSSpaceAdapter()
        adapter = cgs.isAvailable ? cgs : StandardSpaceAdapter()
    }

    deinit {
        MainActor.assumeIsolated {
            adapter.tearDown()
        }
    }
}
