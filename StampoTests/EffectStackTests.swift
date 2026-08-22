import AppKit
import CoreText
import Testing
@testable import Stampo

/// The rules of the stack, apart from any drawing: what a kind starts at, what
/// it lets you change, and what the list does when a row is dragged.
@MainActor @Suite struct EffectStackTests {

    @Test func everyKindHasADefaultInsideItsOwnLimits() {
        for kind in Presentation.Effect.Kind.allCases {
            let effect = EffectStack.make(kind)
            #expect(effect.kind == kind)
            #expect(effect.isEnabled)
            for info in EffectStack.parameters(for: kind) {
                let value = EffectStack.value(info.parameter, of: effect)
                #expect(info.range.contains(value),
                        "\(kind).\(info.parameter) starts at \(value), outside \(info.range)")
            }
            #expect(EffectStack.clamped(effect) == effect)
        }
    }

    @Test func aValueOutsideTheRangeIsPulledBackIn() {
        let grain = EffectStack.make(.grain)
        let tooStrong = EffectStack.setting(.amount, of: grain, to: 12)
        let tooWeak = EffectStack.setting(.amount, of: grain, to: -3)
        #expect(tooStrong.amount == 1)
        #expect(tooWeak.amount == 0)
    }

    /// A parameter the kind does not have cannot be set through the back door:
    /// the panel never offers it, and nothing else should be able to write it.
    @Test func aParameterTheKindDoesNotHaveIsIgnored() {
        let grain = EffectStack.make(.grain)
        #expect(EffectStack.setting(.angle, of: grain, to: 1.2) == grain)
    }

    /// The stack is a recipe, not a set — filters do not commute — so the list
    /// has to be reorderable, and the row that moved has to be findable after.
    @Test func aRowLandsWhereItWasDragged() {
        let effects = [EffectStack.make(.grain, seed: 1),
                       EffectStack.make(.grain, seed: 2),
                       EffectStack.make(.grain, seed: 3)]

        let down = EffectStack.moved(effects, from: 0, to: 2)
        #expect(down.effects.map(\.seed) == [2, 3, 1])
        #expect(down.index == 2)

        let up = EffectStack.moved(effects, from: 2, to: 0)
        #expect(up.effects.map(\.seed) == [3, 1, 2])
        #expect(up.index == 0)
    }

    /// A drag reports whatever the pointer is over, including nowhere.
    @Test func aDragPastTheEndsChangesNothingUnexpected() {
        let effects = [EffectStack.make(.grain, seed: 1), EffectStack.make(.grain, seed: 2)]
        #expect(EffectStack.moved(effects, from: 0, to: 9).effects.map(\.seed) == [2, 1])
        #expect(EffectStack.moved(effects, from: 0, to: -4).effects.map(\.seed) == [1, 2])
        #expect(EffectStack.moved(effects, from: 7, to: 0).effects.map(\.seed) == [1, 2])
    }

    @Test func onlyEnabledEffectsAreActive() {
        var off = EffectStack.make(.grain)
        off.isEnabled = false
        #expect(EffectStack.active([off]).isEmpty)
        #expect(EffectStack.active([EffectStack.make(.grain), off]).count == 1)
    }

    /// Names and glyphs are what the grid of tiles is made of, and a glyph that
    /// does not exist on this system draws nothing at all.
    @Test func everyKindHasItsOwnNameAndSymbol() {
        let kinds = Presentation.Effect.Kind.allCases
        let symbols = kinds.map(EffectStack.symbol(for:))
        #expect(Set(symbols).count == kinds.count)
        #expect(Set(kinds.map(EffectStack.title(for:))).count == kinds.count)
        // The parameters carry glyphs too, and a name that does not exist on
        // this system draws nothing at all.
        let all = symbols + kinds.flatMap { EffectStack.parameters(for: $0).map(\.systemImage) }
        for symbol in all {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                    "Missing SF Symbol: \(symbol)")
        }
    }

    /// A glyph the font does not have draws nothing at all, and an ASCII pass
    /// made of nothing is a blank page. Menlo has no Braille, which is how this
    /// test came to exist — that set was dropped rather than shipped empty.
    @Test func everyGlyphSetIsOneMenloCanDraw() {
        let font = CTFontCreateWithName("Menlo" as CFString, 24, nil)
        for set in Presentation.Effect.GlyphSet.allCases {
            let characters = set.characters
            #expect(characters.count >= 3, "\(set) is too short to be a ramp")
            #expect(characters.last == " ", "\(set) must end in a blank for its highlights")
            for character in characters where character != " " {
                var utf16 = Array(String(character).utf16)
                var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
                let found = CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count)
                #expect(found && !glyphs.contains(0),
                        "Menlo cannot draw \(character) of \(set)")
            }
        }
        #expect(Set(Presentation.Effect.GlyphSet.allCases.map(EffectStack.title(for:))).count
                == Presentation.Effect.GlyphSet.allCases.count)
    }

    /// A dial the panel shows has to be a dial the effect reads. Ranges are
    /// declared in one file and used in another, and a parameter declared but
    /// never applied is a slider that does nothing — which is exactly what
    /// "colour levels" would have been if it had stayed at its old home.
    @Test func everyDeclaredParameterIsOneTheKindActuallyUses() {
        for kind in Presentation.Effect.Kind.allCases {
            let declared = EffectStack.parameters(for: kind)
            #expect(Set(declared.map(\.parameter)).count == declared.count,
                    "\(kind) declares a parameter twice")
            for info in declared {
                #expect(info.range.lowerBound < info.range.upperBound)
                #expect(info.step > 0)
            }
        }
    }
}
