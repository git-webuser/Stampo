import Carbon.HIToolbox
import Foundation
import Testing
@testable import Stampo

/// The ⌃⌥⌘P → L / ⌃⌥⌘T → P move that freed T for Translate.
///
/// Worth this many tests because the failure mode is silent: two actions on
/// one combo passes every check the app performs at runtime, and Carbon simply
/// declines the second registration. Nothing appears in the UI to say a
/// shortcut stopped working.
@MainActor
@Suite struct HotkeyPinReshuffleTests {

    private static let mods = UInt32(controlKey | optionKey | cmdKey)

    private func combo(_ key: Int) -> HotkeyCombo {
        HotkeyCombo(keyCode: UInt16(key), carbonModifiers: Self.mods)
    }

    /// A defaults store with nothing in it, isolated per test.
    private func freshDefaults() -> UserDefaults {
        let suite = "reshuffle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private struct Stored: Codable { let combo: HotkeyCombo? }

    private func store(_ action: HotkeyAction, _ combo: HotkeyCombo?, in defaults: UserDefaults) {
        let data = try! JSONEncoder().encode(Stored(combo: combo))
        defaults.set(data, forKey: "hotkey.combo.\(action.rawValue)")
    }

    private func read(_ action: HotkeyAction, in defaults: UserDefaults) -> HotkeyCombo?? {
        guard let data = defaults.data(forKey: "hotkey.combo.\(action.rawValue)") else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data).combo
    }

    // MARK: Defaults

    @Test func newDefaultsAreTheReshuffledOnes() {
        #expect(HotkeyAction.pinLastCapture.defaultCombo == combo(kVK_ANSI_L))
        #expect(HotkeyAction.collectFiles.defaultCombo == combo(kVK_ANSI_P))
        #expect(HotkeyAction.translateClipboard.defaultCombo == combo(kVK_ANSI_T))
    }

    @Test func defaultsStayUniqueAcrossEveryAction() {
        let combos = HotkeyAction.allCases.map(\.defaultCombo)
        #expect(Set(combos).count == combos.count)
    }

    // MARK: Migration

    @Test func untouchedInstallNeedsNoWrites() {
        // Nothing stored means the action follows `defaultCombo`, which already
        // changed in code. The migration must not freeze those users by
        // writing the current value into storage.
        let defaults = freshDefaults()
        HotkeyAction.migratePinReshuffleIfNeeded(defaults: defaults)

        for action in HotkeyAction.allCases {
            #expect(read(action, in: defaults) == nil, "\(action) should stay unstored")
        }
    }

    @Test func factoryBindsFollowTheMove() {
        let defaults = freshDefaults()
        store(.pinLastCapture, combo(kVK_ANSI_P), in: defaults)
        store(.collectFiles, combo(kVK_ANSI_T), in: defaults)

        HotkeyAction.migratePinReshuffleIfNeeded(defaults: defaults)

        #expect(read(.pinLastCapture, in: defaults) == combo(kVK_ANSI_L))
        #expect(read(.collectFiles, in: defaults) == combo(kVK_ANSI_P))
    }

    @Test func aChosenBindIsNeverMoved() {
        let defaults = freshDefaults()
        store(.pinLastCapture, combo(kVK_ANSI_9), in: defaults)
        store(.collectFiles, combo(kVK_ANSI_T), in: defaults)

        HotkeyAction.migratePinReshuffleIfNeeded(defaults: defaults)

        #expect(read(.pinLastCapture, in: defaults) == combo(kVK_ANSI_9))
        #expect(read(.collectFiles, in: defaults) == combo(kVK_ANSI_P))
    }

    @Test func aDisabledActionStaysDisabled() {
        let defaults = freshDefaults()
        store(.pinLastCapture, nil, in: defaults)

        HotkeyAction.migratePinReshuffleIfNeeded(defaults: defaults)

        #expect(read(.pinLastCapture, in: defaults) == .some(nil))
    }

    // MARK: Collisions

    @Test func migrationNeverLeavesTwoActionsOnOneCombo() {
        // Every arrangement that could put something in the way of a move:
        // occupying the destination, sitting on the freed key, or being the
        // action the whole reshuffle was making room for.
        let arrangements: [[(HotkeyAction, HotkeyCombo?)]] = [
            [(.togglePanel, combo(kVK_ANSI_L)), (.pinLastCapture, combo(kVK_ANSI_P))],
            [(.shareLastItem, combo(kVK_ANSI_P)), (.collectFiles, combo(kVK_ANSI_T))],
            [(.pinLastCapture, nil), (.color, combo(kVK_ANSI_P)), (.collectFiles, combo(kVK_ANSI_T))],
            [(.scan, combo(kVK_ANSI_T)), (.collectFiles, combo(kVK_ANSI_T))],
            [(.pinLastCapture, combo(kVK_ANSI_P)), (.collectFiles, combo(kVK_ANSI_T)),
             (.window, combo(kVK_ANSI_L))],
        ]

        for (index, arrangement) in arrangements.enumerated() {
            let defaults = freshDefaults()
            for (action, value) in arrangement { store(action, value, in: defaults) }

            HotkeyAction.migratePinReshuffleIfNeeded(defaults: defaults)

            var seen: [HotkeyCombo: HotkeyAction] = [:]
            for action in HotkeyAction.allCases {
                let effective: HotkeyCombo?
                switch read(action, in: defaults) {
                case .some(let stored): effective = stored
                case .none:             effective = action.defaultCombo
                }
                guard let effective else { continue }
                if let other = seen[effective] {
                    Issue.record("arrangement \(index): \(action) and \(other) share \(effective.displayString)")
                }
                seen[effective] = action
            }
        }
    }

    @Test func aChosenBindOutranksAFactoryOne() {
        // Someone put another action on ⌃⌥⌘L by hand. The deliberate choice
        // survives; the one that merely wanted to move there gives way, and
        // gives way visibly rather than being shadowed by Carbon.
        let defaults = freshDefaults()
        store(.togglePanel, combo(kVK_ANSI_L), in: defaults)
        store(.pinLastCapture, combo(kVK_ANSI_P), in: defaults)

        HotkeyAction.migratePinReshuffleIfNeeded(defaults: defaults)

        #expect(read(.togglePanel, in: defaults) == combo(kVK_ANSI_L))
        #expect(read(.pinLastCapture, in: defaults) == .some(nil))
    }

    @Test func migrationRunsOnlyOnce() {
        let defaults = freshDefaults()
        store(.pinLastCapture, combo(kVK_ANSI_P), in: defaults)
        HotkeyAction.migratePinReshuffleIfNeeded(defaults: defaults)

        // A second pass must not treat the now-migrated value as a fresh
        // factory bind and move it again.
        store(.pinLastCapture, combo(kVK_ANSI_P), in: defaults)
        HotkeyAction.migratePinReshuffleIfNeeded(defaults: defaults)

        #expect(read(.pinLastCapture, in: defaults) == combo(kVK_ANSI_P))
    }
}
