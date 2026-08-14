import AppKit
import OSLog

// MARK: - Private CGS cursor API

// CGSSetConnectionProperty with key "SetsCursorInBackground" lets this process
// control the cursor even when it is not the foreground application.
// Used by the capture overlays to keep the software cursor visible while
// hovering over windows owned by other processes.
// Without this the window server hands cursor control to the other process
// as soon as the pointer enters one of its windows.
//
// The symbols are private CoreGraphics API, resolved at runtime via dlsym so
// that a future macOS removing them degrades to "cursor may not override
// while backgrounded" instead of a dyld crash at launch.
enum CGSCursorBridge {
    private typealias DefaultConnectionFn = @convention(c) () -> Int32
    private typealias SetConnectionPropertyFn =
        @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Void

    // RTLD_DEFAULT is not importable in Swift on macOS; -2 is its documented
    // bit pattern (see <dlfcn.h>).
    private static let fns: (conn: DefaultConnectionFn, set: SetConnectionPropertyFn)? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let conn = dlsym(rtldDefault, "_CGSDefaultConnection"),
              let set = dlsym(rtldDefault, "CGSSetConnectionProperty")
        else {
            Log.input.error("CGS cursor symbols unavailable; background cursor override disabled")
            return nil
        }
        return (unsafeBitCast(conn, to: DefaultConnectionFn.self),
                unsafeBitCast(set, to: SetConnectionPropertyFn.self))
    }()

    static var isAvailable: Bool { fns != nil }

    static func setCursorInBackground(_ enabled: Bool) {
        guard let fns else { return }
        let cid = fns.conn()
        fns.set(cid, cid, "SetsCursorInBackground" as CFString,
                enabled ? kCFBooleanTrue : kCFBooleanFalse)
    }
}

// MARK: - ESC observation helper

/// Esc handling for a capture overlay's lifetime.
///
/// The primary path is a Carbon hotkey via TransientHotkeyCenter.escape: permission-free
/// and independent of key-window status. (The old global keyDown NSEvent
/// monitor silently required Input Monitoring — with the permission gone it
/// received nothing, so Esc-cancel died whenever the nonactivating overlay
/// wasn't key.) A local monitor stays as fallback for the rare case the
/// hotkey registration fails (Esc claimed by another app) while our overlay
/// is key; with the hotkey active it simply never fires.
final class EscObservation {
    private var token: UUID?
    private var localMonitor: Any?

    init(action: @escaping () -> Void) {
        token = TransientHotkeyCenter.escape.push(action)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == KeyCode.escape { action(); return nil }
            return event
        }
    }

    /// Idempotent; must be called when the overlay is dismissed — while the
    /// center token is held, Esc is consumed system-wide.
    func cancel() {
        if let token {
            TransientHotkeyCenter.escape.remove(token)
            self.token = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }
}

// MARK: - Screen coordinate conversion

/// Height of the primary display (origin == .zero) — Y-flip anchor for AppKit↔CG conversions.
func cgPrimaryDisplayHeight(fallback screen: NSScreen) -> CGFloat {
    NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
        ?? screen.frame.height
}

/// View/overlay rect (AppKit, y=0 at screen bottom) → global CG rect (y=0 at top of primary display).
func viewRectToCGRect(_ rect: CGRect, screen: NSScreen) -> CGRect {
    viewRectToCGRect(rect, panelOrigin: screen.frame.origin, screen: screen)
}

/// View-local rect → global CG rect for an overlay whose panel does **not**
/// cover a whole display — the editor's scanner, which sits over the rect its
/// image occupies so the window's own controls stay live.
///
/// `panelOrigin` is that panel's origin in AppKit screen coordinates. The
/// full-screen form above is this one with the display's own origin: what the
/// view's coordinates are relative to is the panel, and only for a panel
/// filling the display are the two the same.
func viewRectToCGRect(_ rect: CGRect, panelOrigin: CGPoint, screen: NSScreen) -> CGRect {
    let h = cgPrimaryDisplayHeight(fallback: screen)
    return CGRect(
        x: rect.minX + panelOrigin.x,
        y: h - (rect.maxY + panelOrigin.y),
        width: rect.width,
        height: rect.height
    )
}

/// View-local point → global CG point.
func viewPointToCGPoint(_ pt: CGPoint, screen: NSScreen) -> CGPoint {
    let h = cgPrimaryDisplayHeight(fallback: screen)
    return CGPoint(
        x: pt.x + screen.frame.minX,
        y: h - (pt.y + screen.frame.minY)
    )
}

/// Global CG rect → view-local rect.
func cgRectToViewRect(_ rect: CGRect, screen: NSScreen) -> CGRect {
    let h = cgPrimaryDisplayHeight(fallback: screen)
    return CGRect(
        x: rect.minX - screen.frame.minX,
        y: h - rect.maxY - screen.frame.minY,
        width: rect.width,
        height: rect.height
    )
}

// MARK: - Shared overlay panel factory

/// Creates a borderless, full-screen NSPanel suitable for both capture overlays.
func makeOverlayPanel(frame: NSRect) -> NSPanel {
    let panel = NSPanel(
        contentRect: frame,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.level = .screenSaver
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.appearance = NSAppearance(named: .darkAqua)
    return panel
}
