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
