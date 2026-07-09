import Carbon.HIToolbox
import Testing
@testable import Stampo

@Suite struct HotkeyActionOcrTests {

    @Test func ocrDefaultComboIsCtrlOptCmdT() {
        let combo = HotkeyAction.ocr.defaultCombo
        #expect(combo.keyCode == UInt16(kVK_ANSI_T))
        #expect(combo.carbonModifiers == UInt32(controlKey | optionKey | cmdKey))
        #expect(combo.displayString == "⌃⌥⌘T")
    }

    @Test func ocrDefaultComboIsNotSystemReserved() {
        // The pure systemReserved check runs before the Carbon probe, so a
        // reserved default would surface here as .systemReserved.
        let result = HotkeyValidator.validate(HotkeyAction.ocr.defaultCombo, for: .ocr)
        #expect(result != .systemReserved)
        #expect(result != .noStrongModifier)
    }

    @Test func defaultCombosAreUniqueAcrossActions() {
        let combos = HotkeyAction.allCases.map(\.defaultCombo)
        #expect(Set(combos).count == combos.count)
    }

    @Test func rawValuesAreUniqueCarbonIDs() {
        let ids = HotkeyAction.allCases.map(\.rawValue)
        #expect(Set(ids).count == ids.count)
        #expect(HotkeyAction.ocr.rawValue == 6)
    }

    @Test func ocrRowMetadataIsFilledIn() {
        #expect(HotkeyAction.ocr.labelKey == "Capture Text")
        #expect(HotkeyAction.ocr.icon == "text.viewfinder")
    }
}
