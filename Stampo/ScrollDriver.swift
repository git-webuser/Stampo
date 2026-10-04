import AppKit
import ApplicationServices
import CoreGraphics

struct ScrollViewport: Equatable, Sendable {
    /// Viewport within the selected window, in Quartz points.
    let windowRect: CGRect
    /// The hit point relative to the window, so moving the window can rebase it.
    let relativeScrollPoint: CGPoint
    let windowBounds: CGRect
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
        return CGRect(x: bounds["X"] as? CGFloat ?? 0,
                      y: bounds["Y"] as? CGFloat ?? 0,
                      width: bounds["Width"] as? CGFloat ?? 0,
                      height: bounds["Height"] as? CGFloat ?? 0)
    }

    private static func stringAttribute(_ element: AXUIElement, _ key: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? String
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
