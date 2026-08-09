import AppKit
import Carbon
import OSLog

/// Permission-free handling of a bare key via a Carbon hotkey.
///
/// Replaces the listen-only keyDown CGEventTaps that watched for Esc (panel
/// close, color-picker cancel): CGEventTap needs Input Monitoring even for a
/// listen-only tap, while `RegisterEventHotKey` needs no TCC permission at all.
///
/// The semantic difference: a registered hotkey CONSUMES the key system-wide
/// instead of observing it. Two rules keep that acceptable:
///  - the hotkey exists only while at least one owner is pushed (panel on
///    screen, picker session active) — the key behaves normally the rest of
///    the time;
///  - owners form a stack and the most recently pushed one wins, so a picker
///    started on top of the open panel gets the Esc, not the panel.
///
/// Space is the second user, and a far touchier one: swallowing it while the
/// user types would be unforgivable. Its owner is pushed only while the
/// pointer rests on an archive cell — the cursor being parked on our panel is
/// what makes it safe to claim the key.
@MainActor
final class TransientHotkeyCenter {
    /// Closes the topmost surface.
    static let escape = TransientHotkeyCenter(keyCode: UInt32(kVK_Escape),
                                              signature: 0x5354_4553 /* 'STES' */, id: 1)
    /// Quick Look for the archive cell under the pointer.
    static let space = TransientHotkeyCenter(keyCode: UInt32(kVK_Space),
                                             signature: 0x5354_514C /* 'STQL' */, id: 1)
    /// Cycles whatever the open panel's header offers — the colour format in
    /// the archive, the language in the translator. Pushed only while the
    /// pointer is on the panel, for the reason Space is: a claimed key is
    /// claimed for every app on the machine, and a pinned panel would
    /// otherwise eat Tab in the editor the user is actually typing in.
    static let tab = TransientHotkeyCenter(keyCode: UInt32(kVK_Tab),
                                           signature: 0x5354_4359 /* 'STCY' */, id: 1)
    /// The same, backwards. Its own registration because a Carbon hotkey
    /// matches one exact set of modifiers — bare Tab does not fire for ⇧⇥.
    static let shiftTab = TransientHotkeyCenter(keyCode: UInt32(kVK_Tab),
                                                modifiers: UInt32(shiftKey),
                                                signature: 0x5354_4342 /* 'STCB' */, id: 1)

    private let keyCode: UInt32
    private let modifiers: UInt32
    private let signature: UInt32
    private let hotKeyIdentifier: UInt32

    private init(keyCode: UInt32, modifiers: UInt32 = 0, signature: UInt32, id: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.signature = signature
        self.hotKeyIdentifier = id
    }

    private struct Owner {
        let id: UUID
        let action: () -> Void
    }

    private var owners: [Owner] = []
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Registers `action` as the current handler for this key. Returns a token
    /// for `remove(_:)`. The caller MUST remove the token when its surface
    /// leaves the screen — while any owner is pushed, the key is consumed
    /// system-wide.
    @discardableResult
    func push(_ action: @escaping () -> Void) -> UUID {
        let owner = Owner(id: UUID(), action: action)
        owners.append(owner)
        if owners.count == 1 { registerHotKey() }
        return owner.id
    }

    /// True while the key is claimed system-wide. Exposed because that is the
    /// dangerous half of this type: an owner left behind keeps swallowing the
    /// key for every app on the machine.
    var isArmed: Bool { !owners.isEmpty }

    func remove(_ id: UUID) {
        owners.removeAll { $0.id == id }
        if owners.isEmpty { unregisterHotKey() }
    }

    /// Drops every owner and hands the key back, whether or not anyone
    /// remembered their token.
    ///
    /// The safety net for owners whose token dies with them. The panel's Esc
    /// token is a field on the controller and is removed by hand when the panel
    /// is torn down; the archive's Space token lives in SwiftUI `@State`, and a
    /// teardown that releases the hosting view outright (sleep, wake, a display
    /// change — see `invalidatePanelAfterEnvironmentChange`) takes that state
    /// with it before `onDisappear` is guaranteed to have run. The token would
    /// be gone and the owner still pushed: Space swallowed system-wide, with
    /// nothing left holding the handle to let go of it.
    func releaseAll() {
        guard !owners.isEmpty else { return }
        owners.removeAll()
        unregisterHotKey()
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
                    // before earlier-installed handlers. Consume only this
                    // instance's own hotkey — swallowing foreign events turned
                    // every action hotkey into Esc while the panel was open.
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
                    let center = Unmanaged<TransientHotkeyCenter>
                        .fromOpaque(userData).takeUnretainedValue()
                    guard status == noErr,
                          hotKeyID.signature == OSType(center.signature),
                          hotKeyID.id == center.hotKeyIdentifier
                    else { return OSStatus(eventNotHandledErr) }

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { center.fireTopOwner() }
                    }
                    return noErr
                },
                1, &eventType, selfPtr, &handlerRef
            )
        }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(signature), id: hotKeyIdentifier)
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            // The key is claimed by another app's hotkey — rare; local
            // monitors in the overlays still handle Esc when our windows are key.
            Log.input.error("TransientHotkeyCenter: RegisterEventHotKey failed (\(status))")
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
