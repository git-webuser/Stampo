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

    /// Control is the only modifier that can be held while digits are typed —
    /// the system binds it to no digit, where Option would type `∞` and Command
    /// would hand `0` to the editor's zoom. So Control carries the first step
    /// and Command, read at the commit, the second.
    @Test func theModifiersReadAsAgreed() {
        #expect(PresentationInspector.spread(for: []) == .one)
        #expect(PresentationInspector.spread(for: [.control]) == .pair)
        #expect(PresentationInspector.spread(for: [.control, .command]) == .all)
        // Command on its own means nothing here: it is the second half of a
        // gesture, not a gesture.
        #expect(PresentationInspector.spread(for: [.command]) == .one)
        #expect(PresentationInspector.spread(for: [.option]) == .one)
        #expect(PresentationInspector.spread(for: [.shift, .control]) == .pair)
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
