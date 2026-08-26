import Foundation
import Testing
@testable import Stampo

/// Every word the editor shows on hover, checked against the string catalogue.
///
/// `hoverTip` takes a plain `String`, because the tooltip is resolved through
/// `LocaleManager` rather than through SwiftUI's environment — which is what
/// makes the in-app language override work, and also what hides every one of
/// these keys from Xcode's extractor. Nothing warns when a new tooltip is
/// added and never translated: it simply shows its own key, in English, to a
/// Russian reader. "Фигуры" was lost that way and nobody noticed for a while.
///
/// So the catalogue is checked from here instead — and by reading the source
/// rather than a list somebody has to remember to add to. A list would be one
/// more place to forget.
@Suite struct EditorTooltipTests {

    /// The repository, found from this file rather than from the bundle: the
    /// tests are hosted by the app, whose bundle carries the compiled
    /// catalogue, not the sources.
    private static let root: URL = URL(filePath: #filePath)
        .deletingLastPathComponent()   // StampoTests
        .deletingLastPathComponent()   // repo

    /// Keys that carry a Russian translation.
    private static let translated: Set<String> = {
        let url = root.appending(path: "Stampo/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = json["strings"] as? [String: Any] else { return [] }
        var translated: Set<String> = []
        for (key, entry) in strings {
            guard let entry = entry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let russian = localizations["ru"] as? [String: Any],
                  let unit = russian["stringUnit"] as? [String: Any],
                  let value = unit["value"] as? String, !value.isEmpty
            else { continue }
            translated.insert(key)
        }
        return translated
    }()

    private static func swiftSources() -> [URL] {
        let app = root.appending(path: "Stampo")
        guard let walker = FileManager.default.enumerator(at: app,
                                                          includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The two ways these checks could pass while proving nothing: a
    /// catalogue that was never read, and one that appears to hold whatever it
    /// is asked for.
    @Test func theCatalogueWasFoundAndIsNotABlanketYes() {
        #expect(Self.translated.count > 100,
                "the string catalogue was not read — every check below would pass emptily")
        #expect(!Self.translated.contains("A Key Nobody Wrote"))
    }

    /// Every `hoverTip("…")` written out in the source.
    @Test func everyTooltipInTheSourceIsTranslated() throws {
        let pattern = try NSRegularExpression(pattern: #"hoverTip\(\s*"((?:[^"\\]|\\.)+)""#)
        var found: Set<String> = []
        for file in Self.swiftSources() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: text) else { continue }
                found.insert(String(text[keyRange]))
            }
        }
        #expect(found.count >= 20, "the tooltips were not found; has hoverTip been renamed?")
        let missing = found.subtracting(Self.translated).sorted()
        #expect(missing.isEmpty, "tooltips with no Russian: \(missing)")
    }

    /// And the ones handed to `hoverTip` as values rather than written at the
    /// call site — the lists they come from, checked whole.
    @Test func everyTooltipFromAListIsTranslated() {
        var keys = Set(EditorTool.allCases.map(\.labelKey))
        keys.formUnion(CanvasRatio.presets.map(\.titleKey))
        keys.formUnion(PresentationInspector.backgroundPresetNamesForTesting)
        keys.formUnion(EditorView.annotationColorNames)
        let missing = keys.subtracting(Self.translated).sorted()
        #expect(missing.isEmpty, "tooltips with no Russian: \(missing)")
    }
}
