import AppKit

/// Tells the user's hands from the capture's own while it scrolls by itself.
///
/// The capture sends wheel events and reads what the page does; anything else
/// that moves the page — a scroll of the user's, a click, a key — spoils the
/// step in flight and leaves the frames unable to line up, or worse, lining up
/// wrongly. So during the automatic scroll any such input stops it, and what is
/// collected can be saved.
nonisolated enum ScrollInputGuard {
    /// Written into `eventSourceUserData` of every wheel event the capture
    /// posts, so that its own events, which reach a global monitor like any
    /// other, are known for what they are.
    static let syntheticMarker: Int64 = 0x5354_5343_524C_4C31

    enum Kind: Equatable {
        case scrollWheel
        case mouseDown
        case key(isEscape: Bool)
        case pointerMoved
    }

    /// What the capture does about an event.
    enum Response: Equatable {
        /// Nothing: the event is the capture's own, or harmless.
        case none
        /// Pause, and say so in a toast: the user's hands are on the page.
        case pauseAnnounced
        /// Pause without a word: the pointer left the page, most likely for Save.
        case pauseQuietly
    }

    /// What an event, if it is the user taking over, makes the capture do.
    ///
    /// - A wheel event is the user's unless it carries the marker.
    /// - A button press is always the user's.
    /// - A key is, except Esc, which cancels the capture on its own account.
    /// - The pointer is only the user's when it has left the selected window —
    ///   and is not over Stampo's own strip, where the buttons are. That one is
    ///   no news to the user, who is probably on the way to Save.
    ///
    /// Events delivered to Stampo's own windows, the strip and its buttons,
    /// never reach a global monitor, which is what makes clicking Save safe.
    static func response(to kind: Kind, userData: Int64, pointer: CGPoint, window: CGRect,
                         overOwnUI: Bool) -> Response {
        switch kind {
        case .scrollWheel:       return userData != syntheticMarker ? .pauseAnnounced : .none
        case .mouseDown:         return .pauseAnnounced
        case .key(let isEscape): return isEscape ? .none : .pauseAnnounced
        case .pointerMoved:      return !window.contains(pointer) && !overOwnUI ? .pauseQuietly : .none
        }
    }

    /// A point in AppKit's screen space (origin bottom left, y up) as the window
    /// list has it (origin top left of the primary display, y down).
    static func quartzPoint(fromAppKit point: NSPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}

/// Watches for the user's input while the capture scrolls, and says so.
@MainActor
final class ScrollInputMonitor {
    private var monitor: Any?
    private let windowBounds: () -> CGRect
    private let overOwnUI: (CGPoint) -> Bool
    private let onUserInput: (_ announce: Bool) -> Void
    /// The window's bounds, asked of the window list at most a few times a
    /// second: the pointer moves far more often than a window does.
    private var cachedBounds: (rect: CGRect, at: Date)?

    init(windowBounds: @escaping () -> CGRect, overOwnUI: @escaping (CGPoint) -> Bool,
         onUserInput: @escaping (_ announce: Bool) -> Void) {
        self.windowBounds = windowBounds
        self.overOwnUI = overOwnUI
        self.onUserInput = onUserInput
    }

    isolated deinit { stop() }

    func start() {
        guard monitor == nil else { return }
        let types: NSEvent.EventTypeMask = [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                            .keyDown, .mouseMoved]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: types) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        let kind: ScrollInputGuard.Kind
        switch event.type {
        case .scrollWheel:
            // The tail of a gesture that began before the capture did is
            // momentum, not a hand on the trackpad.
            guard event.momentumPhase.isEmpty else { return }
            kind = .scrollWheel
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .mouseDown
        case .keyDown: kind = .key(isEscape: event.keyCode == KeyCode.escape)
        case .mouseMoved: kind = .pointerMoved
        default: return
        }
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.screens.first?.frame.height ?? 0
        let pointer = ScrollInputGuard.quartzPoint(fromAppKit: NSEvent.mouseLocation, primaryHeight: primaryHeight)
        let userData = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
        // Only the pointer needs to know where the window and the strip are.
        let isPointer = kind == .pointerMoved
        switch ScrollInputGuard.response(to: kind, userData: userData, pointer: pointer,
                                         window: isPointer ? currentWindowBounds() : .zero,
                                         overOwnUI: isPointer && overOwnUI(pointer)) {
        case .none:           break
        case .pauseAnnounced: onUserInput(true)
        case .pauseQuietly:   onUserInput(false)
        }
    }

    private func currentWindowBounds() -> CGRect {
        if let cachedBounds, Date().timeIntervalSince(cachedBounds.at) < 0.3 { return cachedBounds.rect }
        let rect = windowBounds()
        cachedBounds = (rect, Date())
        return rect
    }
}
