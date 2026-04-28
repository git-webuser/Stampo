import AppKit
import CoreGraphics

// MARK: - FrontmostWindowResolver

/// Resolves the CGWindowID of the frontmost on-screen window.
/// Used by ScreenshotService to target a specific window for `-l` capture.
enum FrontmostWindowResolver {
    static func frontmostWindowID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0 else { continue }
            guard let isOnscreen = info[kCGWindowIsOnscreen as String] as? Bool,
                  isOnscreen else { continue }
            guard let windowNumber = info[kCGWindowNumber as String] as? UInt32
            else { continue }

            if let bounds = info[kCGWindowBounds as String] as? [String: Any] {
                let wAny = bounds["Width"]
                let hAny = bounds["Height"]
                let w: Double = (wAny as? Double) ?? Double((wAny as? CGFloat) ?? 0)
                let h: Double = (hAny as? Double) ?? Double((hAny as? CGFloat) ?? 0)
                if w <= 0 || h <= 0 { continue }
                if (w < 60 && h < 60) || (w * h < 3600) { continue }
            }

            return CGWindowID(windowNumber)
        }
        return nil
    }
}
