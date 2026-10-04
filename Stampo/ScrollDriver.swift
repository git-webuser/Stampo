import AppKit
import ApplicationServices
import CoreGraphics
import os

nonisolated struct ScrollAncestorCandidate<Identity: Equatable> {
    let identity: Identity
    let role: String
    let frame: CGRect
}

nonisolated enum ScrollAncestorResolver {
    static func isSuitable(role: String, frame: CGRect, windowBounds: CGRect) -> Bool {
        guard role == (kAXScrollAreaRole as String) || role == "AXWebArea" || role == "AXTable" else {
            return false
        }
        let visible = frame.intersection(windowBounds)
        return visible.width >= 80 && visible.height >= 80
    }

    static func nearestSuitableIdentity<Identity: Equatable>(
        in ancestors: [ScrollAncestorCandidate<Identity>], windowBounds: CGRect
    ) -> Identity? {
        ancestors.first(where: { isSuitable(role: $0.role, frame: $0.frame, windowBounds: windowBounds) })?.identity
    }

    static func matchesSelectedIdentity<Identity: Equatable>(
        _ selected: Identity, in ancestors: [ScrollAncestorCandidate<Identity>], windowBounds: CGRect
    ) -> Bool {
        nearestSuitableIdentity(in: ancestors, windowBounds: windowBounds) == selected
    }
}

nonisolated enum ScrollbarEdgeResolver {
    static func inset(for frame: CGRect, viewport: CGRect, axis: ScrollAxis) -> CGFloat? {
        guard !frame.isNull, !frame.isEmpty else { return nil }
        if axis == .vertical, frame.width <= 32, frame.height >= viewport.height * 0.35 {
            let edgeDistance = min(abs(frame.minX - viewport.maxX), abs(frame.maxX - viewport.maxX))
            guard edgeDistance <= 20 else { return nil }
            return frame.minX >= viewport.maxX ? 0 : min(24, max(1, viewport.maxX - frame.minX + 2))
        }
        if axis == .horizontal, frame.height <= 32, frame.width >= viewport.width * 0.35 {
            let edgeDistance = min(abs(frame.minY - viewport.maxY), abs(frame.maxY - viewport.maxY))
            guard edgeDistance <= 20 else { return nil }
            return frame.minY >= viewport.maxY ? 0 : min(24, max(1, viewport.maxY - frame.minY + 2))
        }
        return nil
    }
}

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
                              relativeScrollPoint: relativeScrollPoint,
                              windowBounds: windowBounds)
    }

    func insetWindowEdges(points: CGFloat) -> ScrollViewport? {
        guard points > 0 else { return self }
        let crop = cropRectInWindowPoints
        let tolerance: CGFloat = 1.5
        let left = crop.minX <= tolerance ? points : 0
        let top = crop.minY <= tolerance ? points : 0
        let right = windowBounds.width - crop.maxX <= tolerance ? points : 0
        let bottom = windowBounds.height - crop.maxY <= tolerance ? points : 0
        return inset(left: left, top: top, right: right, bottom: bottom)
    }

    func excludingScrollbar(axis: ScrollAxis, insetPoints: CGFloat) -> ScrollViewport? {
        guard insetPoints > 0 else { return self }
        return axis == .vertical
            ? inset(left: 0, top: 0, right: insetPoints, bottom: 0)
            : inset(left: 0, top: 0, right: 0, bottom: insetPoints)
    }

    private func inset(left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) -> ScrollViewport? {
        let rect = CGRect(x: windowRect.minX + left, y: windowRect.minY + top,
                          width: windowRect.width - left - right,
                          height: windowRect.height - top - bottom)
        guard rect.width >= 40, rect.height >= 40 else { return nil }
        return ScrollViewport(windowRect: rect, relativeScrollPoint: relativeScrollPoint,
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
    case noMovingContent
    case eventUnavailable

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied: return LocaleManager.shared.string("Grant Accessibility access to Stampo to send scroll events.")
        case .scrollAreaUnavailable: return LocaleManager.shared.string("Stampo could not identify a scrollable area at that point. Click inside the page or table and try again.")
        case .noMovingContent: return LocaleManager.shared.string("The scrolling area did not move enough to match frames. Try clicking inside the page or table and start again.")
        case .eventUnavailable: return LocaleManager.shared.string("macOS could not send a scroll event to the selected window.")
        }
    }
}

enum ScrollViewportResolution {
    case accessibility(viewport: ScrollViewport, container: AXUIElement)
    case window(viewport: ScrollViewport)
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
        app.activate(options: [.activateAllWindows])
        // The picker selected a concrete CG window. If that exact window is
        // already topmost at the original click point, no AX window lookup is
        // needed (Chromium can expose incomplete window geometry).
        if let top = frontmostWindow(at: selection.clickPoint),
           top.windowID == selection.windowID, top.processID == selection.processID { return }
        let application = AXUIElementCreateApplication(selection.processID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement],
              let selected = windows.compactMap({ window -> (AXUIElement, CGFloat)? in
                  guard let frame = frameOf(window) else { return nil }
                  let dx = frame.midX - selection.bounds.midX, dy = frame.midY - selection.bounds.midY
                  return (window, dx * dx + dy * dy)
              }).min(by: { $0.1 < $1.1 })?.0 else {
            throw selectedWindowNotFrontmost()
        }
        if AXUIElementPerformAction(selected, kAXRaiseAction as CFString) == .success {
            // Activation/raise can settle asynchronously. The session verifies
            // the exact CG window and PID at the click point before scrolling.
            return
        }
        if let top = frontmostWindow(at: selection.clickPoint),
           top.windowID == selection.windowID, top.processID == selection.processID {
            return
        }
        throw selectedWindowNotFrontmost()
    }

    static func isSelectedWindow(_ windowID: CGWindowID, ownerPID: pid_t) -> Bool {
        currentWindowOwnerPID(windowID) == ownerPID
    }

    static func validateSelectedWindow(selection: WindowPickerSelection, point: CGPoint) throws {
        guard let top = frontmostWindow(at: point),
              top.windowID == selection.windowID,
              top.processID == selection.processID else {
            throw selectedWindowNotFrontmost()
        }
    }

    static func validateScrollTarget(selection: WindowPickerSelection, point: CGPoint,
                                     container: AXUIElement) throws {
        guard let top = frontmostWindow(at: point),
              top.windowID == selection.windowID,
              top.processID == selection.processID else {
            throw selectedWindowNotFrontmost()
        }
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              var current = hit else { throw ScrollDriverError.scrollAreaUnavailable }
        var ancestors: [AXUIElement] = []
        var selectedWindowFrame: CGRect?
        for _ in 0..<16 {
            ancestors.append(current)
            if stringAttribute(current, kAXRoleAttribute as String) == (kAXWindowRole as String) {
                selectedWindowFrame = frameOf(current)
                break
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { break }
            current = (next as! AXUIElement)
        }
        guard let selectedWindowFrame, sameWindowFrame(selectedWindowFrame, top.bounds),
              let selectedIndex = ancestors.firstIndex(where: { CFEqual($0, container) }) else {
            throw ScrollDriverError.scrollAreaUnavailable
        }
        let candidates = ancestors.enumerated().compactMap { index, element -> ScrollAncestorCandidate<Int>? in
            guard let role = stringAttribute(element, kAXRoleAttribute as String),
                  let frame = frameOf(element) else { return nil }
            return ScrollAncestorCandidate(identity: index, role: role, frame: frame)
        }
        guard ScrollAncestorResolver.matchesSelectedIdentity(selectedIndex, in: candidates,
                                                              windowBounds: top.bounds) else {
            throw ScrollDriverError.scrollAreaUnavailable
        }
    }

    static func windowFallbackViewport(for selection: WindowPickerSelection) -> ScrollViewport {
        ScrollViewport(windowRect: selection.bounds,
                       relativeScrollPoint: CGPoint(x: selection.clickPoint.x - selection.bounds.minX,
                                                    y: selection.clickPoint.y - selection.bounds.minY),
                       windowBounds: selection.bounds)
    }

    /// Finds the AX scrollbar attached to the scroll container or its nearby
    /// ancestors. A fixed edge reserve is used when AX has no scrollbar node.
    static func scrollbarInsetPoints(container: AXUIElement?, viewport: CGRect,
                                     axis: ScrollAxis) -> CGFloat? {
        guard let container else { return nil }
        var roots = [container]
        var current = container
        for _ in 0..<3 {
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { break }
            current = (next as! AXUIElement)
            roots.append(current)
        }
        for root in roots {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &value) == .success,
                  let children = value as? [AXUIElement] else { continue }
            for child in children.prefix(128) {
                guard stringAttribute(child, kAXRoleAttribute as String) == "AXScrollBar",
                      let frame = frameOf(child),
                      let inset = ScrollbarEdgeResolver.inset(for: frame, viewport: viewport, axis: axis) else { continue }
                return inset
            }
        }
        return nil
    }

    static func viewport(selection: WindowPickerSelection) throws -> ScrollViewportResolution {
        guard AXIsProcessTrusted() else { throw ScrollDriverError.accessibilityDenied }
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(system, Float(selection.clickPoint.x), Float(selection.clickPoint.y), &hit)
        let windowViewport = windowFallbackViewport(for: selection)
        guard result == .success, let hit else {
            Log.capture.info("scroll viewport fallback · AXError \(result.rawValue, privacy: .public) · hit element unavailable")
            return .window(viewport: windowViewport)
        }

        var current: AXUIElement? = hit
        var scrollRect: CGRect?
        var scrollContainer: AXUIElement?
        var chain: [String] = []
        for _ in 0..<14 {
            guard let element = current else { break }
            let role = stringAttribute(element, kAXRoleAttribute as String) ?? "<role-unavailable>"
            let frame = frameOf(element)
            let geometry = frame.map { String(format: "%.0f,%.0f %.0fx%.0f", $0.minX, $0.minY, $0.width, $0.height) } ?? "<frame-unavailable>"
            chain.append("\(role)@\(geometry)")
            if let frame,
               ScrollAncestorResolver.isSuitable(role: role, frame: frame,
                                                 windowBounds: selection.bounds) {
                let rect = frame.intersection(selection.bounds)
                scrollRect = rect
                scrollContainer = element
                break
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { break }
            current = (next as! AXUIElement)
        }
        guard let rect = scrollRect, rect.width >= 80, rect.height >= 80,
              let resolvedContainer = scrollContainer else {
            Log.capture.info("scroll viewport fallback · AXError \(result.rawValue, privacy: .public) · chain \(chain.joined(separator: " > "), privacy: .public)")
            return .window(viewport: windowViewport)
        }
        Log.capture.info("scroll viewport resolved · AXError \(result.rawValue, privacy: .public) · chain \(chain.joined(separator: " > "), privacy: .public) · viewport \(rect.debugDescription, privacy: .public)")
        return .accessibility(viewport: ScrollViewport(windowRect: rect,
                                                        relativeScrollPoint: CGPoint(x: selection.clickPoint.x - selection.bounds.minX,
                                                                                     y: selection.clickPoint.y - selection.bounds.minY),
                                                        windowBounds: selection.bounds),
                              container: resolvedContainer)
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

    private static func selectedWindowNotFrontmost() -> WindowFrameSourceError {
        .captureFailed(LocaleManager.shared.string("The selected window is covered at the scroll point. Finish to save the collected portion or Cancel to discard."))
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
