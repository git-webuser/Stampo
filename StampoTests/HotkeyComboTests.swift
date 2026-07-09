import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Stampo

@Suite struct HotkeyComboTests {

    private let ctrlOptCmd = UInt32(controlKey | optionKey | cmdKey)

    @Test func displayStringUsesCanonicalModifierOrder() {
        // ⌃ ⌥ ⇧ ⌘, then the key label.
        let combo = HotkeyCombo(
            keyCode: UInt16(kVK_ANSI_N),
            carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        #expect(combo.displayString == "⌃⌥⇧⌘N")
        #expect(combo.displayCaps == ["⌃", "⌥", "⇧", "⌘", "N"])
    }

    @Test func modifierFlagsRoundTripThroughCarbonMask() {
        let mask = HotkeyCombo.carbonMask(from: [.command, .option, .control, .shift])
        #expect(mask == UInt32(cmdKey | optionKey | controlKey | shiftKey))
        #expect(HotkeyCombo.carbonMask(from: []) == 0)
        #expect(HotkeyCombo.carbonMask(from: [.command]) == UInt32(cmdKey))
    }

    @Test func modifierAccessors() {
        let combo = HotkeyCombo(keyCode: UInt16(kVK_ANSI_R), carbonModifiers: ctrlOptCmd)
        #expect(combo.hasControl)
        #expect(combo.hasOption)
        #expect(combo.hasCommand)
        #expect(!combo.hasShift)
    }

    @Test func bareShiftIsNotAStrongModifier() {
        let shiftOnly = HotkeyCombo(keyCode: UInt16(kVK_ANSI_A),
                                    carbonModifiers: UInt32(shiftKey))
        #expect(!shiftOnly.hasStrongModifier)
        let withCmd = HotkeyCombo(keyCode: UInt16(kVK_ANSI_A),
                                  carbonModifiers: UInt32(shiftKey | cmdKey))
        #expect(withCmd.hasStrongModifier)
    }

    @Test func keyLabelsForNamedAndUnknownKeys() {
        #expect(HotkeyCombo.keyLabel(for: UInt16(kVK_ANSI_N)) == "N")
        #expect(HotkeyCombo.keyLabel(for: UInt16(kVK_Space)) == "␣")
        #expect(HotkeyCombo.keyLabel(for: UInt16(kVK_Escape)) == "⎋")
        #expect(HotkeyCombo.keyLabel(for: UInt16(kVK_F12)) == "F12")
        #expect(HotkeyCombo.keyLabel(for: UInt16.max) == "?")
    }

    @Test func codableRoundTrip() throws {
        let combo = HotkeyCombo(keyCode: UInt16(kVK_ANSI_T), carbonModifiers: ctrlOptCmd)
        let data = try JSONEncoder().encode(combo)
        let decoded = try JSONDecoder().decode(HotkeyCombo.self, from: data)
        #expect(decoded == combo)
    }
}
