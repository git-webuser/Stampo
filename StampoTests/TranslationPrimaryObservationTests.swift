import Foundation
import Observation
import Testing
@testable import Stampo

nonisolated private final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set() {
        lock.withLock { storage = true }
    }
}

/// `@Observable` tracks stored properties. `primary` was a computed property
/// over `UserDefaults`, so setting it notified nobody: the picker in Settings
/// went on showing the old language until something unrelated redrew the pane,
/// which in practice meant closing the window and opening it again.
@MainActor
@Suite struct TranslationPrimaryObservationTests {

    @Test func changingThePrimaryLanguageNotifiesTheViewsReadingIt() async {
        let store = TranslationLanguages.shared
        let defaults = UserDefaults.standard
        let key = AppSettings.Keys.translationPrimary
        let saved = defaults.string(forKey: key)
        defer {
            store.primary = saved.map { Locale.Language(identifier: $0) }
            if saved == nil { defaults.removeObject(forKey: key) }
        }

        let notified = ObservationFlag()
        withObservationTracking {
            _ = store.primary
        } onChange: {
            notified.set()
        }

        // Any language will do, and deliberately one that need not be in the
        // list: what is under test is that the property is *stored* and so
        // publishes. Resolving it against the list is a separate rule with its
        // own test, and depending on the list here would make this pass
        // vacuously on a machine that has none.
        store.primary = Locale.Language(identifier: "de")

        #expect(notified.value, "a view reading `primary` must be told when it changes")
    }
}
