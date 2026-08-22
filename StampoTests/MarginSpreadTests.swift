import AppKit
import CoreGraphics
import Testing
@testable import Stampo

/// One typed number, reaching one edge, a pair or all four. The switch in the
/// middle of the cross says "these are the same" as a standing decision; the
/// modifier says "and this one too, just now".
@MainActor @Suite struct MarginSpreadTests {

    @Test func aSpreadNamesTheEdgesItReaches() {
        #expect(PresentationLayout.edges(spreading: .top, .one) == [.top])
        #expect(PresentationLayout.edges(spreading: .leading, .pair) == [.leading, .trailing])
        #expect(PresentationLayout.edges(spreading: .bottom, .pair) == [.bottom, .top])
        #expect(Set(PresentationLayout.edges(spreading: .top, .all))
                == Set(PresentationLayout.Edge.allCases))
    }

    /// The button in the middle of the cross cycles, because there are three
    /// states and a toggle can only say two.
    @Test func theButtonCyclesThroughAllThree() {
        var spread = PresentationLayout.MarginSpread.one
        spread = spread.next
        #expect(spread == .pair)
        spread = spread.next
        #expect(spread == .all)
        spread = spread.next
        #expect(spread == .one)   // and round again
    }

    /// Each state has its own glyph, and the glyph is the whole explanation —
    /// the modes had none at all when they lived on modifier keys.
    @Test func everyStateHasItsOwnSymbol() {
        let symbols = PresentationLayout.MarginSpread.allCases
            .map(PresentationInspector.marginSpreadSymbol)

        #expect(Set(symbols).count == symbols.count)
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                    "Missing SF Symbol: \(symbol)")
        }
    }

    /// However many edges one Return reaches, it is one step to undo.
    @Test func oneNumberIsOneUndoStepWhateverItReaches() {
        let ctx = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let document = EditorDocument(baseImage: ctx.makeImage()!,
                                      sourceURL: URL(fileURLWithPath: "/tmp/spread.png"))
        document.startDecorationIfNeeded()
        let before = document.presentation
        let steps = document.undoStack.count

        document.beginChange()
        for edge in PresentationLayout.edges(spreading: .leading, .all) {
            document.setGap(edge, to: 120)
        }
        document.commitChange()

        let gaps = PresentationLayout.gaps(
            PresentationLayout.resolve(imagePixelSize: document.pixelSize,
                                       document.presentation))
        #expect(gaps.leading == 120)
        #expect(gaps.trailing == 120)
        #expect(gaps.top == 120)
        #expect(gaps.bottom == 120)
        #expect(document.undoStack.count == steps + 1)

        document.undo()
        #expect(document.presentation == before)
    }
}
