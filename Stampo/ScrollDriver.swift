import AppKit
import ApplicationServices
import CoreGraphics
import os

nonisolated struct ScrollAncestorCandidate<Identity: Equatable> {
    let identity: Identity
    let role: String
    let frame: CGRect
    /// Whether the element has a horizontal scroll bar — looked for only on
    /// the elements that could be the scroll area, and only for a capture that
    /// goes sideways.
    var hasHorizontalScrollBar = false
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

    /// The scroll area for a capture along `axis`, from the elements under the
    /// point, nearest first. Down it is the nearest suitable one. Sideways it is
    /// the nearest suitable one that has a horizontal scroll bar: in the
    /// Finder's columns the nearest is one column — a list that scrolls down —
    /// and the one that scrolls sideways is the browser around the columns. If
    /// none has a bar, the nearest suitable one, as before.
    static func chosenIdentity<Identity: Equatable>(
        in ancestors: [ScrollAncestorCandidate<Identity>], windowBounds: CGRect, axis: ScrollAxis
    ) -> Identity? {
        let suitable = ancestors.filter { isSuitable(role: $0.role, frame: $0.frame, windowBounds: windowBounds) }
        if axis == .horizontal, let sideways = suitable.first(where: \.hasHorizontalScrollBar) {
            return sideways.identity
        }
        return suitable.first?.identity
    }

    static func matchesSelectedIdentity<Identity: Equatable>(
        _ selected: Identity, in ancestors: [ScrollAncestorCandidate<Identity>], windowBounds: CGRect,
        axis: ScrollAxis = .vertical
    ) -> Bool {
        chosenIdentity(in: ancestors, windowBounds: windowBounds, axis: axis) == selected
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

/// Why scrolling a window failed. Nothing here is shown to the user: before the
/// first frame the capture falls back to a plain screenshot of the window
/// (Accessibility refused has an alert of its own), and after it a toast says
/// only that it stopped. The text is for the log, in English.
enum ScrollDriverError: Error, LocalizedError {
    case accessibilityDenied
    case scrollAreaUnavailable
    case noMovingContent
    case eventUnavailable
    /// Something is over the point a wheel event would be sent to.
    case pointCovered
    /// Mid-capture the window list gave the window another size, or another scale.
    case windowSizeChanged
    case displayScaleChanged

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied: return "Accessibility access is not granted."
        case .scrollAreaUnavailable: return "There's no scrollable area at that point."
        case .noMovingContent: return "The area doesn't scroll."
        case .eventUnavailable: return "macOS couldn't scroll the window."
        case .pointCovered: return "The window is covered at the scroll point."
        case .windowSizeChanged: return "The window size changed."
        case .displayScaleChanged: return "The display scale changed."
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
    /// AX calls run on the main thread; a hung target app must not stall it
    /// for the default six seconds.
    private static let messagingTimeout: Float = 1.0

    static func accessibilityIsTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func raiseSelectedWindow(_ selection: WindowPickerSelection, ignoring: Set<CGWindowID> = []) throws {
        guard AXIsProcessTrusted() else { throw ScrollDriverError.accessibilityDenied }
        guard let app = NSRunningApplication(processIdentifier: selection.processID) else {
            throw ScrollDriverError.scrollAreaUnavailable
        }
        app.activate(options: [.activateAllWindows])
        // The picker selected a concrete CG window. If that exact window is
        // already topmost at the original click point, no AX window lookup is
        // needed (Chromium can expose incomplete window geometry).
        if let top = frontmostWindow(at: selection.clickPoint, ignoring: ignoring),
           top.windowID == selection.windowID, top.processID == selection.processID { return }
        let application = AXUIElementCreateApplication(selection.processID)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
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
        if let top = frontmostWindow(at: selection.clickPoint, ignoring: ignoring),
           top.windowID == selection.windowID, top.processID == selection.processID {
            return
        }
        throw selectedWindowNotFrontmost()
    }

    static func validateSelectedWindow(selection: WindowPickerSelection, point: CGPoint,
                                       ignoring: Set<CGWindowID> = []) throws {
        guard let top = frontmostWindow(at: point, ignoring: ignoring),
              top.windowID == selection.windowID,
              top.processID == selection.processID else {
            throw selectedWindowNotFrontmost()
        }
    }

    static func validateScrollTarget(selection: WindowPickerSelection, point: CGPoint,
                                     container: AXUIElement, axis: ScrollAxis = .vertical,
                                     ignoring: Set<CGWindowID> = []) throws {
        guard let top = frontmostWindow(at: point, ignoring: ignoring),
              top.windowID == selection.windowID,
              top.processID == selection.processID else {
            throw selectedWindowNotFrontmost()
        }
        let system = systemWideElement()
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
            let sideways = axis == .horizontal
                && ScrollAncestorResolver.isSuitable(role: role, frame: frame, windowBounds: top.bounds)
                && hasHorizontalScrollBar(element)
            return ScrollAncestorCandidate(identity: index, role: role, frame: frame,
                                           hasHorizontalScrollBar: sideways)
        }
        guard ScrollAncestorResolver.matchesSelectedIdentity(selectedIndex, in: candidates,
                                                              windowBounds: top.bounds, axis: axis) else {
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

    /// Whether an element has a horizontal scroll bar.
    static func hasHorizontalScrollBar(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXHorizontalScrollBarAttribute as CFString, &value) == .success,
              let value else { return false }
        return CFGetTypeID(value) == AXUIElementGetTypeID()
    }

    /// The scroll area under the click, for a capture along `axis`. Up the
    /// elements from the click, the first area that could scroll (a scroll
    /// area, a web area, a table); for a capture sideways, the first of them
    /// with a horizontal scroll bar, and if there is none, the first as before.
    static func viewport(selection: WindowPickerSelection, axis: ScrollAxis = .vertical) throws -> ScrollViewportResolution {
        guard AXIsProcessTrusted() else { throw ScrollDriverError.accessibilityDenied }
        let system = systemWideElement()
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(system, Float(selection.clickPoint.x), Float(selection.clickPoint.y), &hit)
        let windowViewport = windowFallbackViewport(for: selection)
        guard result == .success, let hit else {
            Log.capture.notice("scroll viewport fallback · AXError \(result.rawValue, privacy: .public) · hit element unavailable")
            return .window(viewport: windowViewport)
        }

        var current: AXUIElement? = hit
        var elements: [AXUIElement] = []
        var candidates: [ScrollAncestorCandidate<Int>] = []
        var chain: [String] = []
        for _ in 0..<14 {
            guard let element = current else { break }
            let role = stringAttribute(element, kAXRoleAttribute as String) ?? "<role-unavailable>"
            let frame = frameOf(element)
            let geometry = frame.map { String(format: "%.0f,%.0f %.0fx%.0f", $0.minX, $0.minY, $0.width, $0.height) } ?? "<frame-unavailable>"
            if let frame {
                let suitable = ScrollAncestorResolver.isSuitable(role: role, frame: frame,
                                                                 windowBounds: selection.bounds)
                let sideways = suitable && axis == .horizontal && hasHorizontalScrollBar(element)
                chain.append("\(role)@\(geometry)\(sideways ? "+hbar" : "")")
                candidates.append(ScrollAncestorCandidate(identity: elements.count, role: role, frame: frame,
                                                          hasHorizontalScrollBar: sideways))
                elements.append(element)
                // Down: the first area is the one. Sideways: the first with a bar;
                // an area without one is passed over, and kept as the fallback.
                if suitable, axis == .vertical || sideways { break }
            } else {
                chain.append("\(role)@\(geometry)")
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { break }
            current = (next as! AXUIElement)
        }
        guard let index = ScrollAncestorResolver.chosenIdentity(in: candidates, windowBounds: selection.bounds,
                                                                axis: axis) else {
            Log.capture.notice("scroll viewport fallback · AXError \(result.rawValue, privacy: .public) · chain \(chain.joined(separator: " > "), privacy: .public)")
            return .window(viewport: windowViewport)
        }
        let rect = candidates[index].frame.intersection(selection.bounds)
        guard rect.width >= 80, rect.height >= 80 else {
            Log.capture.notice("scroll viewport fallback · AXError \(result.rawValue, privacy: .public) · chain \(chain.joined(separator: " > "), privacy: .public)")
            return .window(viewport: windowViewport)
        }
        Log.capture.notice("scroll viewport resolved · AXError \(result.rawValue, privacy: .public) · chain \(chain.joined(separator: " > "), privacy: .public) · viewport \(rect.debugDescription, privacy: .public)")
        return .accessibility(viewport: ScrollViewport(windowRect: rect,
                                                        relativeScrollPoint: CGPoint(x: selection.clickPoint.x - selection.bounds.minX,
                                                                                     y: selection.clickPoint.y - selection.bounds.minY),
                                                        windowBounds: selection.bounds),
                              container: elements[index])
    }

    /// One wheel event of `lines` lines, forward or `backwards` — up, or left.
    /// How far that moves the page is the app's own business —
    /// `ScrollStepPlanner` works it out from a probe.
    static func sendScroll(axis: ScrollAxis, lines: Int32, backwards: Bool = false, at point: CGPoint) throws {
        guard let event = scrollEvent(axis: axis, lines: lines, backwards: backwards, at: point)
        else { throw ScrollDriverError.eventUnavailable }
        event.post(tap: .cghidEventTap)
    }

    /// The wheel event for `sendScroll`, marked as the capture's own so that
    /// the guard against the user's input can tell it from theirs.
    static func scrollEvent(axis: ScrollAxis, lines: Int32, backwards: Bool = false, at point: CGPoint) -> CGEvent? {
        // Positive wheel counts scroll up and left, so forward is negative.
        let signed = backwards ? lines : -lines
        guard lines > 0,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                  wheel1: axis == .vertical ? signed : 0,
                                  wheel2: axis == .horizontal ? signed : 0, wheel3: 0)
        else { return nil }
        event.location = point
        event.setIntegerValueField(.eventSourceUserData, value: ScrollInputGuard.syntheticMarker)
        return event
    }

    /// Quartz wheel events use small signed counts. The session reasons in
    /// captured pixels; convert its target step to a capped line count and use
    /// this conservative upper bound only for the frame search.
    ///
    /// A line is a distance on screen, so the count follows the step in
    /// points: at 2x a step of 1080 captured pixels is 540 points, the same
    /// six lines as 540 pixels at 1x. Counted from pixels, Retina scrolled
    /// twice as far per event and could outrun the overlap between frames.
    nonisolated static func lineDelta(for pixelStep: Int, backingScale: CGFloat) -> Int32 {
        let points = Int((CGFloat(pixelStep) / max(1, backingScale)).rounded(.up))
        return Int32(min(10, max(1, (points + 99) / 100)))
    }

    nonisolated static func maximumLikelyMovement(pixelStep: Int, backingScale: CGFloat, viewportLength: Int) -> Int {
        let estimate = Int(CGFloat(lineDelta(for: pixelStep, backingScale: backingScale)) * 90 * backingScale)
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

    struct WindowAtPoint: Equatable {
        let windowID: CGWindowID
        let processID: pid_t
        let bounds: CGRect
    }

    /// One row of the window list, front to back.
    struct WindowListEntry: Equatable {
        let windowID: CGWindowID
        let processID: pid_t
        let bounds: CGRect
        let alpha: CGFloat
    }

    /// The window on top at a point. Only `ignoring` is skipped — in practice
    /// the notch panel, whose window is far taller than what it draws and
    /// passes the mouse through (the session asks the panel about its visible
    /// content instead). Any other window of ours over the point counts as
    /// covering it: a picker still fading out would otherwise take a scroll
    /// meant for the page under it.
    nonisolated static func topmostWindow(at point: CGPoint, in entries: [WindowListEntry],
                                          ignoring: Set<CGWindowID>) -> WindowAtPoint? {
        for entry in entries where entry.bounds.contains(point) && entry.alpha > 0.01
            && !ignoring.contains(entry.windowID) {
            return WindowAtPoint(windowID: entry.windowID, processID: entry.processID, bounds: entry.bounds)
        }
        return nil
    }

    /// For the log: the window on top at a point — owner, layer, number and
    /// frame — the one `validateSelectedWindow` compares with the selection.
    static func describeWindow(at point: CGPoint, ignoring: Set<CGWindowID>) -> String {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return "no window list" }
        for info in list {
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = rect(from: bounds), rect.contains(point),
                  let window = info[kCGWindowNumber as String] as? UInt32,
                  !ignoring.contains(CGWindowID(window)),
                  (info[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0.01 else { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            return "\(owner) window \(window) layer \(layer) \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))"
        }
        return "nothing"
    }

    private static func frontmostWindow(at point: CGPoint, ignoring: Set<CGWindowID>) -> WindowAtPoint? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let entries = list.compactMap { info -> WindowListEntry? in
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = rect(from: bounds),
                  let window = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            return WindowListEntry(windowID: CGWindowID(window), processID: pid, bounds: rect,
                                   alpha: info[kCGWindowAlpha as String] as? CGFloat ?? 1)
        }
        return topmostWindow(at: point, in: entries, ignoring: ignoring)
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

    static func selectedWindowNotFrontmost() -> ScrollDriverError {
        .pointCovered
    }

    private static func systemWideElement() -> AXUIElement {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        return system
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
              let p = positionValue, let s = sizeValue,
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}

// MARK: - ScrollStepPlanner

/// How many wheel lines to send for a step, and how far to look for the result.
///
/// A line is not a fixed distance: Safari moves about as far as the guess
/// behind `ScrollDriver.lineDelta`, Chromium about 40 points where that guess
/// says 100 — a step meant as 60% of the screen came out as 30%, and twice as
/// many of them. So the probe, which sends a known number of lines and has its
/// movement measured by the matcher, calibrates the page: pixels per line.
nonisolated enum ScrollStepPlanner {
    static let maxLines = 10

    struct Plan: Equatable {
        let lines: Int32
        /// The farthest the matcher need look for the frames' offset.
        let motionLimit: Int
    }

    /// Pixels one line moved, from a probe of `lines` lines that moved
    /// `offset` pixels. Nil when there is nothing to divide by.
    static func pixelsPerLine(offset: Int, lines: Int) -> Double? {
        guard offset > 0, lines > 0 else { return nil }
        return Double(offset) / Double(lines)
    }

    /// Lines for a target step in pixels: as many as reach it, at least one
    /// and at most ten, then fewer until the step is no more than three
    /// quarters of the frame — the frames must overlap or there is nothing to
    /// stitch them on.
    static func lines(target: Int, pixelsPerLine: Double, axisLength: Int) -> Int {
        guard pixelsPerLine > 0 else { return 1 }
        var lines = min(maxLines, max(1, Int((Double(target) / pixelsPerLine).rounded())))
        let limit = Double(axisLength) * 0.75
        while lines > 1, Double(lines) * pixelsPerLine > limit { lines -= 1 }
        return lines
    }

    /// The matcher's search bound for `lines` lines: half as far again as the
    /// calibration says they move, and a margin, never past three quarters of
    /// the frame.
    static func motionLimit(lines: Int, pixelsPerLine: Double, axisLength: Int) -> Int {
        min(axisLength * 3 / 4, Int((Double(lines) * pixelsPerLine * 1.5 + 32).rounded()))
    }

    // MARK: Predicting a step the frames cannot place

    /// How far a step of `lines` lines should have moved the page, by the
    /// calibration.
    static func predictedOffset(lines: Int, pixelsPerLine: Double) -> Int {
        Int((Double(lines) * pixelsPerLine).rounded())
    }

    /// Whether a step that matched agrees with the calibration: within two
    /// pixels or two percent, whichever is more. One such step is the evidence
    /// that lines move the page linearly, which is what a prediction rests on —
    /// a probe of one line says nothing about ten.
    static func confirmsLinearity(offset: Int, lines: Int, pixelsPerLine: Double) -> Bool {
        let expected = Double(predictedOffset(lines: lines, pixelsPerLine: pixelsPerLine))
        return abs(Double(offset) - expected) <= max(2, expected * 0.02)
    }

    /// How many tiles of the frames must agree with a predicted distance. One
    /// is enough once a full step has shown that lines move the page in
    /// proportion; before that the calibration is one probe, possibly of a
    /// single line, and the frames have to bear it out twice over.
    static func tilesRequiredToAgree(linearityConfirmed: Bool) -> Int {
        linearityConfirmed ? 1 : 2
    }

    /// The step to take. Without a calibration — the probe could not be
    /// matched — it is the estimate from points that has always been used.
    static func plan(target: Int, pixelsPerLine: Double?, axisLength: Int,
                     backingScale: CGFloat) -> Plan {
        guard let pixelsPerLine else {
            return Plan(lines: ScrollDriver.lineDelta(for: target, backingScale: backingScale),
                        motionLimit: ScrollDriver.maximumLikelyMovement(pixelStep: target,
                                                                        backingScale: backingScale,
                                                                        viewportLength: axisLength))
        }
        let lines = lines(target: target, pixelsPerLine: pixelsPerLine, axisLength: axisLength)
        return Plan(lines: Int32(lines),
                    motionLimit: motionLimit(lines: lines, pixelsPerLine: pixelsPerLine,
                                             axisLength: axisLength))
    }
}
