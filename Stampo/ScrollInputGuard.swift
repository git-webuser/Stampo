import AppKit

/// Tells the user's hands from the capture's own while it scrolls by itself.
///
/// The capture sends wheel events and reads what the page does; anything else
/// that moves the page — a scroll of the user's, a click, a key — spoils the
/// step in flight and leaves the frames unable to line up, or worse, lining up
/// wrongly. So during the automatic scroll any such input pauses it. While it
/// is paused the same input is only written down (`UserScrollLedger`), so that
/// the capture can find its place again.
///
/// The pointer is not input. It leaving the window, or resting on Stampo's own
/// strip, makes the capture wait for it (`shouldWait`), since it is most likely
/// on its way to a button.
nonisolated enum ScrollInputGuard {
    /// Written into `eventSourceUserData` of every wheel event the capture
    /// posts, so that its own events, which reach a global monitor like any
    /// other, are known for what they are.
    static let syntheticMarker: Int64 = 0x5354_5343_524C_4C31

    enum Kind: Equatable {
        case scrollWheel
        case mouseDown
        case key(isEscape: Bool)
    }

    /// An event the monitor saw, with what the capture needs of it.
    struct Event: Equatable {
        var kind: Kind
        /// `eventSourceUserData`: the capture's own wheel events carry the mark.
        var userData: Int64 = 0
        /// The wheel's delta in points where the device is precise (a
        /// trackpad), in lines where it is not (a mouse wheel). Positive
        /// scrolls toward the start of the page — up, or left.
        var preciseX = 0.0, preciseY = 0.0
        var lineX = 0.0, lineY = 0.0
        /// The tail of a gesture that has ended: inertia, not a hand.
        var isMomentum = false
    }

    /// What the capture does about an event.
    enum Response: Equatable {
        /// Nothing: the event is the capture's own, or harmless.
        case nothing
        /// Pause, and say so in a toast: the user's hands are on the page.
        case pauseAnnounced
    }

    /// What an event, if it is the user taking over, makes the capture do.
    ///
    /// - A wheel event is the user's unless it carries the marker.
    /// - A button press is always the user's.
    /// - A key is, except Esc, which cancels the capture on its own account.
    ///
    /// Events delivered to Stampo's own windows, the strip and its buttons,
    /// never reach a global monitor, which is what makes clicking them safe.
    static func response(to kind: Kind, userData: Int64) -> Response {
        switch kind {
        case .scrollWheel:       return userData != syntheticMarker ? .pauseAnnounced : .nothing
        case .mouseDown:         return .pauseAnnounced
        case .key(let isEscape): return isEscape ? .nothing : .pauseAnnounced
        }
    }

    /// What the session does with a response, given whether a first strip is in.
    enum Outcome: Equatable {
        case ignore
        /// The window as it stands, instead of a capture that has nothing yet.
        case windowScreenshot
        case pause
    }

    /// With something collected, a response pauses the capture. With nothing —
    /// the first step still in flight — there is nothing for Save to keep: a
    /// hand on the page gives the user the window as it stands.
    static func outcome(of response: Response, hasCollected: Bool) -> Outcome {
        switch response {
        case .nothing:        return .ignore
        case .pauseAnnounced: return hasCollected ? .pause : .windowScreenshot
        }
    }

    /// Whether the capture holds back its next step for the pointer: it is off
    /// the page, or on Stampo's own strip. Either way the user is probably
    /// reaching for a button, and a step sent under their hand is wasted. Not
    /// input, so nothing is stopped; the capture goes on when the pointer is
    /// back in the window.
    static func shouldWait(pointer: CGPoint, window: CGRect, overOwnUI: Bool) -> Bool {
        !window.contains(pointer) || overOwnUI
    }

    /// A point in AppKit's screen space (origin bottom left, y up) as the window
    /// list has it (origin top left of the primary display, y down).
    static func quartzPoint(fromAppKit point: NSPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}

/// What the user did to the page while the capture was paused: the wheel,
/// inertia included, summed; and whether keys that may have moved the page were
/// pressed. From it the capture works out how far to scroll back.
nonisolated struct UserScrollLedger: Equatable {
    /// Along the capture's axis; positive toward the start of the page.
    private(set) var precise = 0.0
    private(set) var lines = 0.0
    /// A key pressed with the selected app in front: something that may have
    /// moved the page — space, an arrow, Page Down — by how much nobody knows.
    /// A click does not, and a key pressed in another app does not.
    private(set) var touched = false

    /// Whether anything was done that could have moved the page.
    var mayHaveMovedPage: Bool { touched || precise != 0 || lines != 0 }

    /// `selectedAppIsFront` is whether the app whose page is captured was the
    /// one in front when the event came: a key goes to the app in front, and
    /// only that one's page can be moved by it. A click does not scroll a page
    /// by itself, and so is never counted.
    mutating func record(_ event: ScrollInputGuard.Event, axis: ScrollAxis, selectedAppIsFront: Bool = true) {
        switch event.kind {
        case .scrollWheel:
            guard event.userData != ScrollInputGuard.syntheticMarker else { return }
            precise += axis == .vertical ? event.preciseY : event.preciseX
            lines += axis == .vertical ? event.lineY : event.lineX
        case .mouseDown:
            break
        case .key(let isEscape):
            if !isEscape, selectedAppIsFront { touched = true }
        }
    }

    /// How far the page moved toward its end, in the captured pixels: the
    /// wheel's points at the display's scale, its lines at what a line was
    /// measured to be (or a plain 80 points a line without a measure). Zero
    /// when only keys and clicks were pressed — those move it by an unknown amount.
    func pageMovement(scale: CGFloat, pixelsPerLine: Double?) -> Int {
        let towardStart = precise * Double(scale) + lines * (pixelsPerLine ?? 80 * Double(scale))
        return Int((-towardStart).rounded())
    }
}

/// Watches the user's input while the capture runs or is paused, and reports it.
@MainActor
final class ScrollInputMonitor {
    private var monitor: Any?
    private let onEvent: (ScrollInputGuard.Event) -> Void

    init(onEvent: @escaping (ScrollInputGuard.Event) -> Void) {
        self.onEvent = onEvent
    }

    isolated deinit { stop() }

    func start() {
        guard monitor == nil else { return }
        let types: NSEvent.EventTypeMask = [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: types) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        var seen: ScrollInputGuard.Event
        switch event.type {
        case .scrollWheel:
            seen = ScrollInputGuard.Event(kind: .scrollWheel)
            seen.userData = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
            if event.hasPreciseScrollingDeltas {
                seen.preciseX = Double(event.scrollingDeltaX)
                seen.preciseY = Double(event.scrollingDeltaY)
            } else {
                seen.lineX = Double(event.deltaX)
                seen.lineY = Double(event.deltaY)
            }
            seen.isMomentum = !event.momentumPhase.isEmpty
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            seen = ScrollInputGuard.Event(kind: .mouseDown)
        case .keyDown:
            seen = ScrollInputGuard.Event(kind: .key(isEscape: event.keyCode == KeyCode.escape))
        default:
            return
        }
        onEvent(seen)
    }
}
