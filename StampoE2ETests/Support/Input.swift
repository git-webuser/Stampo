import AppKit
import ApplicationServices

@MainActor
final class Input {
    private let source: CGEventSource

    init() throws {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw E2EFailure("Grant Accessibility to StampoE2ETests-Runner.app; only the user may change system permissions")
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw E2EFailure("Cannot create a HID event source")
        }
        self.source = source
    }

    func move(to point: CGPoint) throws { try mouse(.mouseMoved, at: point) }

    func click(at point: CGPoint) throws {
        try move(to: point)
        try mouse(.leftMouseDown, at: point)
        defer { try? mouse(.leftMouseUp, at: point) }
    }

    func drag(from start: CGPoint, to end: CGPoint, steps: Int = 24) throws {
        guard steps > 0 else { throw E2EFailure("Drag requires at least one step") }
        try move(to: start)
        try mouse(.leftMouseDown, at: start)
        defer { try? mouse(.leftMouseUp, at: end) }
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            try mouse(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * t,
                                                     y: start.y + (end.y - start.y) * t))
            RunLoop.current.run(until: Date().addingTimeInterval(0.015))
        }
    }

    func scroll(vertical: Int32, horizontal: Int32 = 0) throws {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: vertical, wheel2: horizontal, wheel3: 0) else {
            throw E2EFailure("Cannot construct a scroll event")
        }
        event.post(tap: .cghidEventTap)
    }

    func press(_ chord: String) throws {
        var flags: CGEventFlags = []
        for (symbol, flag) in [("⌃", CGEventFlags.maskControl), ("⌥", .maskAlternate),
                                ("⌘", .maskCommand), ("⇧", .maskShift)] where chord.contains(symbol) {
            flags.insert(flag)
        }
        let key = chord.filter { !"⌃⌥⌘⇧".contains($0) }.uppercased()
        let codes: [String: CGKeyCode] = ["N": 0x2D, "R": 0x0F, "B": 0x0B, "G": 0x05,
                                        "C": 0x08, "S": 0x01, "L": 0x25, "P": 0x23,
                                        "D": 0x02, "T": 0x11, "F": 0x03, "ESC": 0x35]
        guard let code = codes[key] else { throw E2EFailure("Unsupported key chord: \(chord)") }
        // A key-up carrying chord flags leaves those flags in HID state.
        // Pair them with modifier key-ups even though delivery uses event flags.
        defer {
            var remaining = flags
            for (flag, modifier) in [(CGEventFlags.maskShift, CGKeyCode(0x38)),
                                     (.maskCommand, 0x37), (.maskAlternate, 0x3A), (.maskControl, 0x3B)]
                where flags.contains(flag) {
                remaining.remove(flag)
                if let event = CGEvent(keyboardEventSource: source, virtualKey: modifier, keyDown: false) {
                    event.flags = remaining
                    event.post(tap: .cghidEventTap)
                }
            }
        }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
                throw E2EFailure("Cannot construct key event: \(chord)")
            }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    /// Inspect HID state before invariant checks, and release every held
    /// input even when the scenario failed before its normal key/button up.
    func releasePressedState() -> [String] {
        let flags = CGEventSource.flagsState(.hidSystemState)
        let modifiers: [(String, CGEventFlags, [CGKeyCode])] = [
            ("control", .maskControl, [0x3B, 0x3E]),
            ("option", .maskAlternate, [0x3A, 0x3D]),
            ("command", .maskCommand, [0x37, 0x36]),
            ("shift", .maskShift, [0x38, 0x3C])
        ]
        let held = modifiers.filter { flags.contains($0.1) }
        let leftDown = CGEventSource.buttonState(.hidSystemState, button: .left)
        guard !held.isEmpty || leftDown else {
            print("input state clean")
            return []
        }
        let names = held.map { $0.0 } + (leftDown ? ["left mouse"] : [])
        var failures = ["input left pressed: \(names.joined(separator: ", "))"]
        print(failures[0])
        for (_, _, codes) in held {
            for code in codes {
                if let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
                    event.flags = []
                    event.post(tap: .cghidEventTap)
                } else { failures.append("Cannot release modifier key \(code)") }
            }
        }
        if leftDown {
            let point = CGEvent(source: source)?.location ?? Self.quartzPoint(fromAppKit: NSEvent.mouseLocation)
            do { try mouse(.leftMouseUp, at: point) }
            catch { failures.append("Cannot release left mouse: \(error)") }
        }
        return failures
    }

    func park() throws {
        let display = CGDisplayBounds(CGMainDisplayID())
        try move(to: CGPoint(x: display.minX + 20, y: display.maxY - 40))
    }

    // Formulas from Stampo/CaptureOverlayShared.swift (6919d04). AppKit and
    // Quartz share x; y is reflected in the primary display's height, not the
    // currently selected display's height. XCUI frames already use Quartz.
    static var primaryDisplayHeight: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.screens.first?.frame.height ?? 0
    }
    static func quartzPoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayHeight - point.y)
    }
    static func appKitPoint(fromQuartz point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayHeight - point.y)
    }

    private func mouse(_ type: CGEventType, at point: CGPoint) throws {
        guard point.x.isFinite, point.y.isFinite,
              let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else {
            throw E2EFailure("Cannot construct mouse event at \(point)")
        }
        event.post(tap: .cghidEventTap)
    }
}
