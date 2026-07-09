import Carbon.HIToolbox
import Testing
@testable import Stampo

/// Covers only the pure validation branches. `.valid` for a novel combo is
/// deliberately not asserted — that path probes Carbon RegisterEventHotKey
/// and depends on what other apps hold on the machine running the tests.
@Suite struct HotkeyValidatorTests {

    @Test func comboWithoutStrongModifierIsRejected() {
        let shiftOnly = HotkeyCombo(keyCode: UInt16(kVK_ANSI_J),
                                    carbonModifiers: UInt32(shiftKey))
        #expect(HotkeyValidator.validate(shiftOnly, for: .selection) == .noStrongModifier)
        let bare = HotkeyCombo(keyCode: UInt16(kVK_ANSI_J), carbonModifiers: 0)
        #expect(HotkeyValidator.validate(bare, for: .selection) == .noStrongModifier)
    }

    @Test(arguments: [
        (kVK_ANSI_3, shiftKey | cmdKey),          // system screenshot
        (kVK_ANSI_4, shiftKey | cmdKey),
        (kVK_ANSI_5, shiftKey | cmdKey),
        (kVK_Space, cmdKey),                      // Spotlight
        (kVK_Tab, cmdKey),                        // app switcher
        (kVK_ANSI_Q, cmdKey),                     // quit
        (kVK_UpArrow, controlKey),                // Mission Control
    ])
    func systemReservedCombosAreRejected(key: Int, mods: Int) {
        let combo = HotkeyCombo(keyCode: UInt16(key), carbonModifiers: UInt32(mods))
        #expect(HotkeyValidator.validate(combo, for: .selection) == .systemReserved)
    }

    @Test func reRecordingCurrentComboIsValid() {
        // Uses whatever combo is currently persisted for the action; skip
        // silently if the user cleared it on this machine.
        for action in HotkeyAction.allCases {
            guard let combo = action.combo else { continue }
            #expect(HotkeyValidator.validate(combo, for: action) == .valid)
        }
    }

    @Test func anotherActionsComboIsADuplicate() {
        // togglePanel's live combo offered to .selection must be flagged as a
        // duplicate. Skip if cleared or (theoretically) colliding with
        // selection's own combo.
        guard let other = HotkeyAction.togglePanel.combo,
              other.hasStrongModifier,
              other != HotkeyAction.selection.combo
        else { return }
        #expect(HotkeyValidator.validate(other, for: .selection) == .duplicate(.togglePanel))
    }
}
