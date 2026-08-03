import Foundation
import Testing
@testable import Stampo

/// The centre claims a bare key system-wide while any owner is pushed, so the
/// bookkeeping around push/remove is the part worth pinning down: a token left
/// behind means Esc — or worse, Space — stops working everywhere until quit.
@MainActor
@Suite struct TransientHotkeyCenterTests {

    @Test func theKeyIsClaimedOnlyWhileSomeoneOwnsIt() {
        let centre = TransientHotkeyCenter.space
        #expect(!centre.isArmed)

        let token = centre.push {}
        #expect(centre.isArmed)

        centre.remove(token)
        #expect(!centre.isArmed)
    }

    @Test func theKeyStaysClaimedUntilTheLastOwnerLeaves() {
        let centre = TransientHotkeyCenter.space
        let first = centre.push {}
        let second = centre.push {}
        #expect(centre.isArmed)

        centre.remove(first)
        #expect(centre.isArmed)   // the second owner still needs the key

        centre.remove(second)
        #expect(!centre.isArmed)
    }

    @Test func removingAnUnknownTokenChangesNothing() {
        let centre = TransientHotkeyCenter.space
        let token = centre.push {}
        centre.remove(UUID())
        #expect(centre.isArmed)
        centre.remove(token)
        #expect(!centre.isArmed)
    }

    /// The safety net for an owner whose token died with it (the archive keeps
    /// its Space token in SwiftUI `@State`, which a panel teardown can take
    /// away before `onDisappear` runs). Every owner goes, however many there
    /// are and whether or not anyone still holds the token.
    @Test func releasingEverythingHandsTheKeyBack() {
        let centre = TransientHotkeyCenter.space
        centre.push {}
        centre.push {}
        #expect(centre.isArmed)

        centre.releaseAll()
        #expect(!centre.isArmed)
    }

    /// Called on every teardown, most of which claim nothing — and a stray
    /// `unregisterHotKey` on a key that was never registered is not something
    /// to find out about in production.
    @Test func releasingWhenNobodyOwnsTheKeyIsHarmless() {
        let centre = TransientHotkeyCenter.space
        centre.releaseAll()
        #expect(!centre.isArmed)

        // And the centre still works afterwards.
        let token = centre.push {}
        #expect(centre.isArmed)
        centre.remove(token)
        #expect(!centre.isArmed)
    }

    /// A released Space must not take Esc with it: the panel teardown that
    /// calls `releaseAll()` runs while a Quick Look window can still be up,
    /// and that window's Esc is the only way out of it.
    @Test func releasingSpaceLeavesEscapeAlone() {
        let token = TransientHotkeyCenter.escape.push {}
        TransientHotkeyCenter.space.push {}

        TransientHotkeyCenter.space.releaseAll()
        #expect(!TransientHotkeyCenter.space.isArmed)
        #expect(TransientHotkeyCenter.escape.isArmed)

        TransientHotkeyCenter.escape.remove(token)
        #expect(!TransientHotkeyCenter.escape.isArmed)
    }

    /// Esc and Space are separate claims — pushing one must not arm the other,
    /// or opening the panel would swallow Space for the whole machine.
    @Test func escapeAndSpaceAreIndependent() {
        let token = TransientHotkeyCenter.escape.push {}
        #expect(TransientHotkeyCenter.escape.isArmed)
        #expect(!TransientHotkeyCenter.space.isArmed)
        TransientHotkeyCenter.escape.remove(token)
        #expect(!TransientHotkeyCenter.escape.isArmed)
    }
}

/// When the archive claims Space, and — since 'Preview with Space' — when it
/// declines to. The key is taken from every app on the machine while it is
/// held, so each of the three conditions is worth stating outright.
@MainActor
@Suite struct ArchiveSpaceHotkeyTests {

    private let hovered = [URL(fileURLWithPath: "/tmp/space-test.png")]

    @Test func claimedWhileACellIsHovered() {
        #expect(NotchArchiveView.wantsSpaceHotkey(
            enabled: true, isContentVisible: true, hoveredURLs: hovered))
    }

    /// The switch is the point of the whole setting: off means the key is never
    /// ours, not even with the pointer parked on a cell.
    @Test func neverClaimedWhenThePreviewIsTurnedOff() {
        #expect(!NotchArchiveView.wantsSpaceHotkey(
            enabled: false, isContentVisible: true, hoveredURLs: hovered))
    }

    /// The archive can close with the pointer still on a cell (Esc, hotkey,
    /// auto-hide), and no cell reports a hover-out then.
    @Test func notClaimedWhileTheArchiveIsHidden() {
        #expect(!NotchArchiveView.wantsSpaceHotkey(
            enabled: true, isContentVisible: false, hoveredURLs: hovered))
    }

    /// Pointer between cells, or over a colour or a snippet — nothing to
    /// preview, so nothing to hold the key for.
    @Test func notClaimedWithNothingUnderThePointer() {
        #expect(!NotchArchiveView.wantsSpaceHotkey(
            enabled: true, isContentVisible: true, hoveredURLs: []))
    }
}
