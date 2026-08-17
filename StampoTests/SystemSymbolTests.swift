import AppKit
import Testing
@testable import Stampo

/// SF Symbol names are stringly typed: a typo compiles, leaves its button in
/// the layout, and silently produces an empty image. Keep every central symbol
/// registry covered so a new or unavailable name fails at test time.
@Suite struct SystemSymbolTests {

    @Test func editorToolSymbolsExist() {
        assertSymbols(EditorTool.allCases.map(\.systemImage))
    }

    @Test func menuSymbolsExist() {
        assertSymbols(MenuIcon.allCases.map(\.rawValue))
    }

    @Test func dropTargetSymbolsExist() {
        assertSymbols(ArchiveDropZone.allCases.map(\.icon))
    }

    @Test func decorSymbolExists() {
        assertSymbols([PresentationInspector.decorSystemImage])
    }

    @Test func inspectorSectionSymbolsExist() {
        assertSymbols(PresentationInspector.sectionSystemImages)
    }

    @Test func alignmentSymbolsExist() {
        assertSymbols(PresentationInspector.alignmentSystemImages)
    }

    @Test func marginUnlockSymbolExists() {
        assertSymbols(["link.badge.plus"])
    }

    private func assertSymbols(_ names: [String]) {
        for name in names {
            #expect(
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                "Missing SF Symbol: \(name)"
            )
        }
    }
}
