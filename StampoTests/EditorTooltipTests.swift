import AppKit
import Foundation
import Testing
@testable import Stampo

/// Every word the editor shows on hover, checked against what the app actually
/// ships.
///
/// `hoverTip` takes a plain `String`, because the tooltip is resolved through
/// `LocaleManager` rather than through SwiftUI's environment — which is what
/// makes the in-app language override work, and also what hides every one of
/// these keys from Xcode's extractor. Nothing warns when a tooltip is added and
/// never translated: it simply shows its own key, in English, to a Russian
/// reader. "Фигуры" was lost that way and nobody noticed for a while.
///
/// Asked of the built bundle rather than of the repository. The first version
/// of this test read the string catalogue and the sources off disk, which works
/// until the hosted app is denied the folder they are in — and then it does not
/// fail, it *waits*: a single read sat for thirty-five minutes on a machine
/// whose Documents folder the app had no permission to open, and took the whole
/// suite with it. The scan of the sources now lives in
/// `Scripts/check-tooltips.sh`, where the shell that owns the checkout runs it.
@MainActor @Suite struct EditorTooltipTests {

    /// The Russian table as it is compiled into the app.
    private static let russian: Bundle? = {
        guard let path = Bundle.main.path(forResource: "ru", ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }()

    /// A key nobody translated comes back as itself; this is the one sentinel
    /// that cannot be mistaken for a translation.
    private static func isTranslated(_ key: String) -> Bool {
        guard let russian else { return false }
        let missing = "\u{0}absent\u{0}"
        return russian.localizedString(forKey: key, value: missing, table: nil) != missing
    }

    /// The two ways this check could pass while proving nothing: no Russian
    /// table at all, and a table that answers everything.
    @Test func theRussianTableIsThereAndIsNotABlanketYes() {
        #expect(Self.russian != nil, "the app shipped without a Russian table")
        #expect(Self.isTranslated("Shadow"), "a key that is certainly translated reads as missing")
        #expect(!Self.isTranslated("A Key Nobody Wrote"))
    }

    /// The tooltips that reach `hoverTip` as values rather than as literals —
    /// the lists they come from, checked whole. (The literals are scanned out
    /// of the sources by `Scripts/check-tooltips.sh`.)
    @Test func everyTooltipFromAListIsTranslated() {
        var keys = Set(EditorTool.allCases.map(\.labelKey))
        keys.formUnion(CanvasRatio.presets.map(\.titleKey))
        keys.formUnion(PresentationInspector.backgroundPresetNamesForTesting)
        keys.formUnion(EditorView.annotationColorNames)
        let missing = keys.filter { !Self.isTranslated($0) }.sorted()
        #expect(missing.isEmpty, "tooltips with no Russian: \(missing)")
    }
}
