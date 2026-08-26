import AppKit
import OSLog

// MARK: - Ring-buffer trace

/// Lightweight in-process "black box": every event is written to OSLog
/// (visible in Console.app / `log stream`) and kept in a capped ring buffer
/// that can be exported via Copy Diagnostics after a hard-to-reproduce bug.
///
/// Usage:
///   DebugTrace.add("spaceDidChange.visible.orderFront")
///   // …later in About → Copy Diagnostics:
///   DebugTrace.dump()
enum DebugTrace {
    private static let lock = NSLock()
    private static var events: [String] = []
    private static let limit = 800

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func add(_ message: @autoclosure () -> String) {
        let entry = "[\(formatter.string(from: Date()))] \(message())"
        lock.lock()
        events.append(entry)
        if events.count > limit { events.removeFirst(events.count - limit) }
        lock.unlock()
        Log.panel.debug("\(entry, privacy: .public)")
    }

    static func dump() -> String {
        lock.lock()
        defer { lock.unlock() }
        return events.isEmpty ? "(no trace events)" : events.joined(separator: "\n")
    }

    static func clear() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }
}

// MARK: - Panel snapshot helpers

enum PanelTrace {
    static func panelSummary(_ panel: NSPanel?) -> String {
        guard let panel else { return "nil" }
        return "id=\(panel.windowNumber) visible=\(panel.isVisible) key=\(panel.isKeyWindow) " +
               "frame=\(rectStr(panel.frame)) alpha=\(String(format: "%.2f", panel.alphaValue)) " +
               "collection=\(collectionStr(panel.collectionBehavior))"
    }

    static func screenSummary(_ screen: NSScreen?) -> String {
        guard let screen else { return "nil" }
        return "frame=\(rectStr(screen.frame)) visible=\(rectStr(screen.visibleFrame)) " +
               "notch=\(screen.notchGapWidth)"
    }

    /// Coarse region label instead of raw coordinates — precise mouse positions
    /// never end up in logs or user-exported diagnostics.
    static func mouseSummary(_ point: NSPoint = NSEvent.mouseLocation) -> String {
        "mouse=\(regionLabel(for: point))"
    }

    private static func regionLabel(for point: NSPoint) -> String {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
                ?? NSScreen.main else { return "off-screen" }
        let frame = screen.frame
        let nearTop = point.y > frame.maxY - 44
        guard nearTop else { return "elsewhere" }
        let centerBand = abs(point.x - frame.midX) < frame.width * 0.15
        return centerBand ? "near-notch" : "top-edge"
    }

    private static func rectStr(_ r: NSRect) -> String {
        "[\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))]"
    }

    private static func collectionStr(_ b: NSWindow.CollectionBehavior) -> String {
        var parts: [String] = []
        if b.contains(.canJoinAllSpaces)    { parts.append("canJoinAll") }
        if b.contains(.moveToActiveSpace)   { parts.append("moveToActive") }
        if b.contains(.stationary)          { parts.append("stationary") }
        if b.contains(.fullScreenAuxiliary) { parts.append("fsAux") }
        if b.contains(.transient)           { parts.append("transient") }
        return "[\(parts.joined(separator: ","))]"
    }
}

// MARK: - Hide reason

enum PanelHideReason: String {
    case hotkeyToggle
    case notchClick
    case outsideClick
    case escKey
    case closeButton
    case captureStart
    case colorPickerStart
    case environmentInvalidation
    case unknown
}

// MARK: - CustomStringConvertible for state types

extension PanelState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .hidden:                       return "hidden"
        case .showing:                      return "showing"
        case .main:                         return "main"
        case .archive:                      return "archive"
        case .translate:                    return "translate"
        case .hiding:                       return "hiding"
        case .countdown:                    return "countdown"
        case .waiting:                      return "waiting"
        case .transitioning(let t):         return "transitioning(\(t))"
        case .preSelection(let k):          return "preSelection(\(k))"
        case .stale(let r):                 return "stale(\(r))"
        }
    }
}

extension TransitionTarget: CustomStringConvertible {
    public var description: String {
        switch self {
        case .archive:   return "archive"
        case .translate: return "translate"
        case .main:      return "main"
        }
    }
}

extension OverlayKind: CustomStringConvertible {
    public var description: String {
        switch self { case .selection: return "selection"; case .window: return "window" }
    }
}

extension StaleReason: CustomStringConvertible {
    public var description: String {
        switch self {
        case .sleep:         return "sleep"
        case .spaceChange:   return "spaceChange"
        case .displayChange: return "displayChange"
        }
    }
}

extension NotchPanelRoute: CustomStringConvertible {
    public var description: String {
        switch self {
        case .main:      return "main"
        case .archive:   return "archive"
        case .translate: return "translate"
        case .cdwn:      return "cdwn"
        }
    }
}
