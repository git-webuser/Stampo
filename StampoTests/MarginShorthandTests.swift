import AppKit
import CoreGraphics
import Testing
@testable import Stampo

/// Margins written the way stylesheets write them: what a field reads, what it
/// reaches, and what it says back.
///
/// This replaces a suite about a mode called `MarginSpread` — a hidden rule
/// about "where the next number goes", first on modifier keys that could not
/// work and then on a button that explained nothing. The rule is gone; the
/// fields themselves now say what they set.
@MainActor @Suite struct MarginShorthandTests {

    private let margins = Presentation.Margins(top: 1, leading: 2, bottom: 3, trailing: 4)

    @Test func oneNumberInAnAxisFieldSetsBothItsSides() {
        let vertical = MarginShorthand.applied([20], from: .vertical, to: margins)
        #expect(vertical.top == 20 && vertical.bottom == 20)
        #expect(vertical.leading == 2 && vertical.trailing == 4)

        let horizontal = MarginShorthand.applied([20], from: .horizontal, to: margins)
        #expect(horizontal.leading == 20 && horizontal.trailing == 20)
        #expect(horizontal.top == 1 && horizontal.bottom == 3)
    }

    @Test func twoNumbersInAnAxisFieldGoInOrder() {
        let vertical = MarginShorthand.applied([10, 84], from: .vertical, to: margins)
        #expect(vertical.top == 10 && vertical.bottom == 84)

        let horizontal = MarginShorthand.applied([10, 84], from: .horizontal, to: margins)
        #expect(horizontal.leading == 10 && horizontal.trailing == 84)
    }

    @Test func oneNumberInASideFieldSetsThatSideAlone() {
        let result = MarginShorthand.applied([20], from: .side(.leading), to: margins)
        #expect(result.leading == 20)
        #expect(result.trailing == 4 && result.top == 1 && result.bottom == 3)
    }

    /// Three and four numbers are the stylesheet's own meaning and reach every
    /// side, whichever field they were typed into.
    @Test func theShorthandReachesAllFourFromAnyField() {
        let three = MarginShorthand.applied([1, 2, 3], from: .side(.top), to: margins)
        #expect(three == Presentation.Margins(top: 1, leading: 2, bottom: 3, trailing: 2))

        let four = MarginShorthand.applied([1, 2, 3, 4], from: .vertical, to: margins)
        // top, right, bottom, left — going round from the top.
        #expect(four == Presentation.Margins(top: 1, leading: 4, bottom: 3, trailing: 2))
    }

    @Test func nothingTypedChangesNothing() {
        #expect(MarginShorthand.applied([], from: .vertical, to: margins) == margins)
        #expect(MarginShorthand.numbers(in: "abc").isEmpty)
        #expect(MarginShorthand.numbers(in: "12px").isEmpty)
    }

    /// Space and comma both separate, because margins are whole pixels and a
    /// comma here cannot be a decimal point.
    @Test func spaceAndCommaSeparateAlike() {
        #expect(MarginShorthand.numbers(in: "10 84") == [10, 84])
        #expect(MarginShorthand.numbers(in: "10,84") == [10, 84])
        #expect(MarginShorthand.numbers(in: " 10, 84 ") == [10, 84])
    }

    /// A field never claims the two sides agree when they do not.
    @Test func anUnequalPairIsShownAsAPair() {
        let even = Presentation.Margins(top: 84, leading: 84, bottom: 84, trailing: 84)
        #expect(MarginShorthand.text(for: .vertical, of: even) == "84")
        #expect(MarginShorthand.text(for: .vertical, of: margins) == "1 3")
        #expect(MarginShorthand.text(for: .horizontal, of: margins) == "2 4")
        #expect(MarginShorthand.text(for: .side(.trailing), of: margins) == "4")
    }

    /// What a field shows is what it reads back unchanged.
    @Test func whatAFieldShowsIsWhatItReads() {
        for target in [MarginShorthand.Target.vertical, .horizontal,
                       .side(.top), .side(.leading)] {
            let typed = MarginShorthand.values(for: target, of: margins)
            #expect(MarginShorthand.applied(typed, from: target, to: margins) == margins,
                    "\(target) does not round-trip")
        }
    }

    /// Every glyph in a field, and the button beside them, exists on this
    /// system — SF Symbols are measured, never assumed.
    @Test func everyFieldHasItsOwnSymbol() {
        let targets: [MarginShorthand.Target] = [.vertical, .horizontal, .side(.top),
                                                 .side(.bottom), .side(.leading),
                                                 .side(.trailing)]
        let symbols = targets.map(PresentationInspector.marginSymbol)
            + ["arrow.up.left.and.arrow.down.right",
               "arrow.down.right.and.arrow.up.left"]

        #expect(Set(symbols).count == symbols.count)
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                    "Missing SF Symbol: \(symbol)")
        }
    }

    /// However many sides one Return reaches, it is one step to undo.
    @Test func oneNumberIsOneUndoStepWhateverItReaches() {
        let ctx = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let document = EditorDocument(baseImage: ctx.makeImage()!,
                                      sourceURL: URL(fileURLWithPath: "/tmp/shorthand.png"))
        document.startDecorationIfNeeded()
        let before = document.presentation
        let steps = document.undoStack.count

        let current = PresentationLayout.gaps(
            PresentationLayout.resolve(imagePixelSize: document.pixelSize,
                                       document.presentation))
        let updated = MarginShorthand.applied(
            [120], from: .side(.leading),
            to: Presentation.Margins(top: current.top, leading: current.leading,
                                     bottom: current.bottom, trailing: current.trailing))

        document.beginChange()
        for edge in PresentationLayout.Edge.allCases {
            document.setGap(edge, to: updated[edge])
        }
        document.commitChange()

        let gaps = PresentationLayout.gaps(
            PresentationLayout.resolve(imagePixelSize: document.pixelSize,
                                       document.presentation))
        #expect(gaps.leading == 120)
        #expect(gaps.trailing == current.trailing)
        #expect(document.undoStack.count == steps + 1)

        document.undo()
        #expect(document.presentation == before)
    }
}
