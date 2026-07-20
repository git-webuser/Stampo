import AppKit
import Carbon
import OSLog

/// Permission-free global Escape handling via a Carbon hotkey.
///
/// Replaces the listen-only keyDown CGEventTaps that watched for Esc (panel
/// close, color-picker cancel): CGEventTap needs Input Monitoring even for a
/// listen-only tap, while `RegisterEventHotKey` needs no TCC permission at all.
///
/// The semantic difference: a registered hotkey CONSUMES Esc system-wide
/// instead of observing it. Two rules keep that acceptable:
///  - the hotkey exists only while at least one owner is pushed (panel on
///    screen, picker session active) — Esc behaves normally the rest of the
///    time;
///  - owners form a stack and the most recently pushed one wins, so a picker
///    started on top of the open panel gets the Esc, not the panel.
@MainActor
final class EscapeHotkeyCenter {
    static let shared = EscapeHotkeyCenter()

    private struct Owner {
        let id: UUID
        let action: () -> Void
    }

    private var owners: [Owner] = []
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    /// Registers `action` as the current Esc handler. Returns a token for
    /// `remove(_:)`. The caller MUST remove the token when its surface leaves
    /// the screen — while any owner is pushed, Esc is consumed system-wide.
    @discardableResult
    func push(_ action: @escaping () -> Void) -> UUID {
        let owner = Owner(id: UUID(), action: action)
        owners.append(owner)
        if owners.count == 1 { registerHotKey() }
        return owner.id
    }

    func remove(_ id: UUID) {
        owners.removeAll { $0.id == id }
        if owners.isEmpty { unregisterHotKey() }
    }

    private func fireTopOwner() {
        owners.last?.action()
    }

    // MARK: - Carbon plumbing

    private func registerHotKey() {
        guard hotKeyRef == nil else { return }

        if handlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, eventRef, userData in
                    guard let userData, let eventRef else { return noErr }

                    // This handler sees EVERY Carbon hotkey press in the app
                    // (NotchHoverController's actions included) and is called
                    // before earlier-installed handlers. Consume only our own
                    // Esc hotkey — swallowing foreign events turned every
                    // action hotkey into Esc while the panel was open.
                    var hotKeyID = EventHotKeyID()
                    let status = GetEventParameter(
                        eventRef,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &hotKeyID
                    )
                    guard status == noErr,
                          hotKeyID.signature == OSType(0x5354_4553) /* 'STES' */,
                          hotKeyID.id == 1
                    else { return OSStatus(eventNotHandledErr) }

                    let center = Unmanaged<EscapeHotkeyCenter>
                        .fromOpaque(userData).takeUnretainedValue()
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { center.fireTopOwner() }
                    }
                    return noErr
                },
                1, &eventType, selfPtr, &handlerRef
            )
        }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5354_4553) /* 'STES' */, id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape), 0, hotKeyID, GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            // Esc is claimed by another app's hotkey — rare; local monitors in
            // the overlays still handle Esc when our windows are key.
            Log.input.error("EscapeHotkeyCenter: RegisterEventHotKey failed (\(status))")
        }
    }

    private func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = handlerRef {
            RemoveEventHandler(handler)
            handlerRef = nil
        }
    }
}
