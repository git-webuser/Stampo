import AppKit
import SwiftUI
import Testing
@testable import Stampo

/// What the panel asks for in width, which is not a matter of taste: the
/// inspector column grows to the width its content says it needs, so a row
/// that asks for more than the rest widens the whole panel the moment it
/// appears — and one did, the first time a picture was placed on a page.
@MainActor @Suite struct PanelWidthTests {

    private func picture() -> CGImage {
        let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        return ctx.makeImage()!
    }

    /// Folds the sections for one measurement and gives the preference back
    /// afterwards. It is a preference shared with every other test in this
    /// process, and a panel left with its Image section folded away hid the
    /// margin fields that the typing tests reach for.
    private func folding(_ sections: Set<PresentationInspector.Section>,
                         _ body: () -> Void) {
        let key = AppSettings.Keys.decorFoldedSections
        let held = AppSettings.store.string(forKey: key)
        AppSettings.store.set(PresentationInspector.folded(sections), forKey: key)
        body()
        if let held { AppSettings.store.set(held, forKey: key) }
        else { AppSettings.store.removeObject(forKey: key) }
    }

    private func document() -> EditorDocument {
        let doc = EditorDocument(baseImage: picture(),
                                 sourceURL: URL(fileURLWithPath: "/tmp/panel-\(UUID()).png"))
        doc.startDecorationIfNeeded()
        return doc
    }

    /// The width the panel would take if nothing constrained it.
    private func width(_ document: EditorDocument) -> CGFloat {
        // In a window of its own, taken down again straight after: a hosting
        // view left standing keeps the text fields it built alive, and the
        // tests that type into the panel's own fields then find the keyboard
        // somewhere else.
        let view = NSHostingView(rootView: PresentationInspector(document: document,
                                                                colorShelf: nil))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        // Not released when closed: AppKit's default is to release it, and a
        // window created here and closed here would be over-released — which
        // took the whole test process down with it.
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let width = view.fittingSize.width
        window.contentView = nil
        window.close()
        return width
    }

    private func place(on document: EditorDocument) {
        let layout = PresentationLayout.resolve(imagePixelSize: document.pixelSize,
                                                document.presentation)
        document.placePicture(picture(), centredOn: CGPoint(x: 60, y: 60),
                              canvasSize: layout.canvasSize)
    }

    @Test func placingAPictureDoesNotWidenThePanel() {
        let bare = document()
        let withPicture = document()
        place(on: withPicture)
        withPicture.selectedID = withPicture.annotations.last?.id   // its section, open
        withPicture.annotations[0].pictureEffects = [EffectStack.make(.grain)]

        folding(PresentationInspector.foldedByDefault) {
            #expect(width(withPicture) == width(bare),
                    "a placed picture made the panel wider than the page alone does")
        }
    }

    /// And the object's own section fits inside the narrowest the panel is ever
    /// allowed to be, so it cannot push the column even when everything else is
    /// folded away. The strength field beside the colour field is what broke
    /// this: two full-width fields in one row came to 326 against a 320 floor.
    @Test func anObjectsSectionFitsThePanelsMinimumWidth() {
        let document = document()
        place(on: document)
        document.selectedID = document.annotations.last?.id
        document.annotations[0].pictureEffects = [EffectStack.make(.grain)]

        // Every page section folded away, so what is measured is the object.
        folding(Set(PresentationInspector.Section.allCases)) {
            #expect(width(document) <= PresentationInspector.contentMinimumWidth,
                    "the object section asks for more than the panel's minimum width")
        }
    }
}
