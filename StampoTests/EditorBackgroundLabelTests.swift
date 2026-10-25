import Foundation
import Testing
@testable import Stampo

/// The transparent background tile shares its English caption with the
/// shortcut recorder, but Russian needs two different translations. Check
/// compiled tables so the hosted test never needs access to the checkout.
@MainActor @Suite struct EditorBackgroundLabelTests {
    @Test func transparentBackgroundKeepsItsOwnLocalizedKey() throws {
        for (language, background, shortcut) in [
            ("en", "None", "None"),
            ("ru", "Без фона", "Нет")
        ] {
            let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"),
                                    "the app must ship its \(language) localization")
            let bundle = try #require(Bundle(path: path))
            let missing = "\u{0}missing-background-label\u{0}"
            let backgroundLabel = bundle.localizedString(forKey: "No Background", value: missing, table: nil)
            let shortcutLabel = bundle.localizedString(forKey: "None", value: missing, table: nil)

            #expect(backgroundLabel != missing, "No Background is absent in \(language)")
            #expect(shortcutLabel != missing, "None is absent in \(language)")
            #expect(backgroundLabel == background, "transparent background caption in \(language)")
            #expect(shortcutLabel == shortcut, "shortcut placeholder in \(language)")
        }
    }
}
