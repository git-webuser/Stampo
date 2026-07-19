import Carbon.HIToolbox
import Foundation
import Testing
@testable import Stampo

@Suite struct HotkeyActionScanTests {

    @Test func scanDefaultComboIsCtrlOptCmdS() {
        let combo = HotkeyAction.scan.defaultCombo
        #expect(combo.keyCode == UInt16(kVK_ANSI_S))
        #expect(combo.carbonModifiers == UInt32(controlKey | optionKey | cmdKey))
        #expect(combo.displayString == "⌃⌥⌘S")
    }

    @Test func scanDefaultComboIsNotSystemReserved() {
        // The pure systemReserved check runs before the Carbon probe, so a
        // reserved default would surface here as .systemReserved.
        let result = HotkeyValidator.validate(HotkeyAction.scan.defaultCombo, for: .scan)
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
        #expect(HotkeyAction.scan.rawValue == 7)
        // 6 belonged to the retired Capture Text action and must stay unused.
        #expect(HotkeyAction(rawValue: 6) == nil)
    }

    @Test func scanRowMetadataIsFilledIn() {
        #expect(HotkeyAction.scan.labelKey == "Scan")
        #expect(HotkeyAction.scan.icon == "doc.viewfinder")
    }
}

// MARK: - Scan-merge migration

@Suite struct HotkeyScanMergeMigrationTests {

    /// Mirrors the private `Stored` box: `{"combo": ...}` with a nil combo
    /// encoding as `{}` (explicitly disabled once the key exists).
    private struct Stored: Codable { let combo: HotkeyCombo? }

    private static let scanKey = "hotkey.combo.7"
    private static let ocrKey = "hotkey.combo.6"

    private let scanDefault = HotkeyAction.scan.defaultCombo
    private let ocrDefault = HotkeyCombo(
        keyCode: UInt16(kVK_ANSI_T),
        carbonModifiers: UInt32(controlKey | optionKey | cmdKey)
    )
    private let customScan = HotkeyCombo(
        keyCode: UInt16(kVK_ANSI_D),
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )
    private let customOcr = HotkeyCombo(
        keyCode: UInt16(kVK_ANSI_E),
        carbonModifiers: UInt32(optionKey | cmdKey)
    )

    /// Runs `body` against a throwaway defaults suite that is wiped afterwards.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "stampo-scan-merge-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func store(_ combo: HotkeyCombo?, key: String, in defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(Stored(combo: combo)), forKey: key)
    }

    /// nil = never stored; .some(nil) = stored as disabled.
    private func storedScanCombo(in defaults: UserDefaults) throws -> HotkeyCombo?? {
        guard let data = defaults.data(forKey: Self.scanKey) else { return nil }
        return try JSONDecoder().decode(Stored.self, from: data).combo
    }

    @Test func customScanCodeComboBeatsCustomOcrCombo() throws {
        try withDefaults { defaults in
            try store(customScan, key: Self.scanKey, in: defaults)
            try store(customOcr, key: Self.ocrKey, in: defaults)
            HotkeyAction.migrateScanMergeIfNeeded(defaults: defaults)
            #expect(try storedScanCombo(in: defaults) == customScan)
            #expect(defaults.data(forKey: Self.ocrKey) == nil)
        }
    }

    @Test func customOcrComboSurvivesWhenScanCodeWasFactory() throws {
        try withDefaults { defaults in
            try store(scanDefault, key: Self.scanKey, in: defaults)
            try store(customOcr, key: Self.ocrKey, in: defaults)
            HotkeyAction.migrateScanMergeIfNeeded(defaults: defaults)
            #expect(try storedScanCombo(in: defaults) == customOcr)
        }
    }

    @Test func disabledScanCodeIsReenabledByEnabledOcr() throws {
        try withDefaults { defaults in
            try store(nil, key: Self.scanKey, in: defaults)
            try store(ocrDefault, key: Self.ocrKey, in: defaults)
            HotkeyAction.migrateScanMergeIfNeeded(defaults: defaults)
            #expect(try storedScanCombo(in: defaults) == scanDefault)
        }
    }

    @Test func bothDisabledStaysDisabled() throws {
        try withDefaults { defaults in
            try store(nil, key: Self.scanKey, in: defaults)
            try store(nil, key: Self.ocrKey, in: defaults)
            HotkeyAction.migrateScanMergeIfNeeded(defaults: defaults)
            #expect(try storedScanCombo(in: defaults) == HotkeyCombo?.none)
        }
    }

    @Test func bothAtFactoryStateWritesNothing() throws {
        try withDefaults { defaults in
            try store(scanDefault, key: Self.scanKey, in: defaults)
            try store(ocrDefault, key: Self.ocrKey, in: defaults)
            HotkeyAction.migrateScanMergeIfNeeded(defaults: defaults)
            #expect(try storedScanCombo(in: defaults) == scanDefault)
            #expect(defaults.bool(forKey: "hotkeysMergedScanHotkey"))
        }
    }

    @Test func legacyOcrOnlyInstallGetsWorkingScanHotkey() throws {
        // Pre-combo installs stored only the enable bools; a user who kept OCR
        // but disabled Scan Code should end up with the Scan hotkey enabled.
        try withDefaults { defaults in
            try store(nil, key: Self.scanKey, in: defaults)
            defaults.set(true, forKey: "hotkeyOcrEnabled")
            HotkeyAction.migrateScanMergeIfNeeded(defaults: defaults)
            #expect(try storedScanCombo(in: defaults) == scanDefault)
        }
    }

    @Test func migrationRunsOnlyOnce() throws {
        try withDefaults { defaults in
            HotkeyAction.migrateScanMergeIfNeeded(defaults: defaults)
            // A retired-key write appearing later must not be re-merged.
            try store(customOcr, key: Self.ocrKey, in: defaults)
            HotkeyAction.migrateScanMergeIfNeeded(defaults: defaults)
            #expect(try storedScanCombo(in: defaults) == HotkeyCombo??.none)
        }
    }
}
