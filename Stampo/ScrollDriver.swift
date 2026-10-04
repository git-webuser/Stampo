import AppKit
import ApplicationServices
import CoreGraphics

struct ScrollViewport: Equatable, Sendable {
    /// Viewport within the selected window, in Quartz points.
    let windowRect: CGRect
    /// The hit point relative to the window, so moving the window can rebase it.
    let relativeScrollPoint: CGPoint
    let windowBounds: CGRect

    func cropped(to pixelRect: CGRect, backingScale: CGFloat) -> ScrollViewport? {
        guard backingScale > 0, pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        let pointRect = CGRect(x: pixelRect.minX / backingScale, y: pixelRect.minY / backingScale,
                               width: pixelRect.width / backingScale, height: pixelRect.height / backingScale)
        let croppedWindowRect = CGRect(x: windowRect.minX + pointRect.minX,
                                       y: windowRect.minY + pointRect.minY,
                                       width: pointRect.width, height: pointRect.height)
        return ScrollViewport(windowRect: croppedWindowRect,
                              relativeScrollPoint: CGPoint(x: croppedWindowRect.midX - windowBounds.minX,
                                                           y: croppedWindowRect.midY - windowBounds.minY),
                              windowBounds: windowBounds)
    }

    var cropRectInWindowPoints: CGRect {
        CGRect(x: (windowRect.minX - windowBounds.minX),
               y: (windowRect.minY - windowBounds.minY),
               width: windowRect.width, height: windowRect.height)
    }
}

enum ScrollDriverError: Error, LocalizedError {
    case accessibilityDenied
    case scrollAreaUnavailable
    case eventUnavailable

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied: return LocaleManager.shared.string("Grant Accessibility access to Stampo to send scroll events.")
        case .scrollAreaUnavailable: return LocaleManager.shared.string("Stampo could not identify a scrollable area at that point. Click inside the page or table and try again.")
        case .eventUnavailable: return LocaleManager.shared.string("macOS could not send a scroll event to the selected window.")
        }
    }
}

/// Accessibility is used only to find the scrollable viewport. Scrolling is
/// sent as a Core Graphics wheel event at the user's exact click location.
enum ScrollDriver {
    static func accessibilityIsTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func raiseSelectedWindow(_ selection: WindowPickerSelection) throws {
        guard AXIsProcessTrusted() else { throw ScrollDriverError.accessibilityDenied }
        guard let app = NSRunningApplication(processIdentifier: selection.processID) else {
            throw ScrollDriverError.scrollAreaUnavailable
        }
        let application = AXUIElementCreateApplication(selection.processID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement],
              let selected = windows.first(where: { frameOf($0).map { sameWindowFrame($0, selection.bounds) } ?? false })
        else { throw ScrollDriverError.scrollAreaUnavailable }

        app.activate(options: [.activateAllWindows])
        guard AXUIElementPerformAction(selected, kAXRaiseAction as CFString) == .success else {
            throw ScrollDriverError.scrollAreaUnavailable
        }
    }

    static func isSelectedWindow(_ windowID: CGWindowID, ownerPID: pid_t) -> Bool {
        currentWindowOwnerPID(windowID) == ownerPID
    }

    static func validateScrollTarget(selection: WindowPickerSelection, point: CGPoint) throws {
        guard let top = frontmostWindow(at: point),
              top.windowID == selection.windowID,
              top.processID == selection.processID else {
            throw WindowFrameSourceError.captureFailed(LocaleManager.shared.string("The selected window is covered at the scroll point. Finish to save the collected portion or Cancel to discard."))
        }
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              var current = hit else { throw ScrollDriverError.scrollAreaUnavailable }
        var foundScrollableAncestor = false
        for _ in 0..<16 {
            if let role = stringAttribute(current, kAXRoleAttribute as String) {
                if isScrollableRole(role) { foundScrollableAncestor = true }
                if role == (kAXWindowRole as String) {
                    guard foundScrollableAncestor, let frame = frameOf(current), sameWindowFrame(frame, top.bounds) else {
                        throw ScrollDriverError.scrollAreaUnavailable
                    }
                    return
                }
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { break }
            current = (next as! AXUIElement)
        }
        throw ScrollDriverError.scrollAreaUnavailable
    }

    static func viewport(selection: WindowPickerSelection) throws -> ScrollViewport {
        guard AXIsProcessTrusted() else { throw ScrollDriverError.accessibilityDenied }
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(system, Float(selection.clickPoint.x), Float(selection.clickPoint.y), &hit)
        guard result == .success, let hit else { throw ScrollDriverError.scrollAreaUnavailable }

        var current: AXUIElement? = hit
        var scrollRect: CGRect?
        for _ in 0..<14 {
            guard let element = current else { break }
            if let role = stringAttribute(element, kAXRoleAttribute as String),
               role == (kAXScrollAreaRole as String) || role == "AXWebArea" || role == "AXTable" {
                if let frame = frameOf(element), frame.width >= 80, frame.height >= 80 {
                    scrollRect = frame.intersection(selection.bounds)
                    if let rect = scrollRect, rect.width >= 80, rect.height >= 80 { break }
                }
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { break }
            current = (next as! AXUIElement)
        }
        guard let rect = scrollRect, rect.width >= 80, rect.height >= 80 else {
            throw ScrollDriverError.scrollAreaUnavailable
        }
        return ScrollViewport(windowRect: rect,
                              relativeScrollPoint: CGPoint(x: selection.clickPoint.x - selection.bounds.minX,
                                                           y: selection.clickPoint.y - selection.bounds.minY),
                              windowBounds: selection.bounds)
    }

    static func sendScroll(axis: ScrollAxis, pixels: Int, at point: CGPoint) throws {
        let lines = lineDelta(for: pixels)
        guard pixels > 0,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                  wheel1: axis == .vertical ? -lines : 0,
                                  wheel2: axis == .horizontal ? -lines : 0, wheel3: 0)
        else { throw ScrollDriverError.eventUnavailable }
        event.location = point
        event.post(tap: .cghidEventTap)
    }

    /// Quartz wheel events use small signed counts. The session reasons in
    /// captured pixels; convert its target step to a capped line count and use
    /// this conservative upper bound only for the frame search.
    static func lineDelta(for pixelStep: Int) -> Int32 {
        Int32(min(10, max(1, (pixelStep + 99) / 100)))
    }

    static func maximumLikelyMovement(pixelStep: Int, backingScale: CGFloat, viewportLength: Int) -> Int {
        let estimate = Int(CGFloat(lineDelta(for: pixelStep)) * 90 * backingScale)
        return min(max(1, viewportLength * 3 / 4), estimate)
    }

    static func currentWindowBounds(_ windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowID }),
              let bounds = info[kCGWindowBounds as String] as? [String: Any]
        else { return nil }
        return rect(from: bounds)
    }

    static func currentWindowOwnerPID(_ windowID: CGWindowID) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowID })
        else { return nil }
        return info[kCGWindowOwnerPID as String] as? pid_t
    }

    private struct WindowAtPoint {
        let windowID: CGWindowID
        let processID: pid_t
        let bounds: CGRect
    }

    private static func frontmostWindow(at point: CGPoint) -> WindowAtPoint? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = rect(from: bounds), rect.contains(point),
                  (info[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0.01,
                  let window = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            return WindowAtPoint(windowID: CGWindowID(window), processID: pid, bounds: rect)
        }
        return nil
    }

    private static func rect(from bounds: [String: Any]) -> CGRect? {
        guard let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
              let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func sameWindowFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3
            && abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
    }

    private static func stringAttribute(_ element: AXUIElement, _ key: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func isScrollableRole(_ role: String) -> Bool {
        role == (kAXScrollAreaRole as String) || role == "AXWebArea" || role == "AXTable"
    }

    private static func frameOf(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let p = positionValue, let s = sizeValue else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
