import AppKit

// MARK: - Private CGS cursor API

// CGSSetConnectionProperty with key "SetsCursorInBackground" lets this process
// control the cursor even when it is not the foreground application.
// Used by WindowPickerOverlay to keep the software cursor visible while
// hovering over windows owned by other processes.
// Without this the window server hands cursor control to the other process
// as soon as the pointer enters one of its windows.
@_silgen_name("_CGSDefaultConnection")
func _CGSDefaultConnection() -> Int32

@_silgen_name("CGSSetConnectionProperty")
func CGSSetConnectionProperty(
    _ cid: Int32, _ targetCid: Int32, _ key: CFString, _ value: CFTypeRef)

// MARK: - ESC monitor helper

/// Installs both a global and a local monitor for the Escape key.
/// Tokens are appended to `monitors`; the caller must remove them via
/// `NSEvent.removeMonitor` when the overlay is dismissed.
func installEscMonitors(into monitors: inout [Any], action: @escaping () -> Void) {
    if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
        if event.keyCode == KeyCode.escape { action() }
    }) { monitors.append(m) }

    if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
        if event.keyCode == KeyCode.escape { action(); return nil }
        return event
    }) { monitors.append(m) }
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
