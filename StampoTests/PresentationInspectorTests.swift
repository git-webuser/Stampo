import AppKit
import SwiftUI
import Testing
@testable import Stampo

/// The inspector is allowed to *show* a document; it is not allowed to change
/// one. That line is easy to cross by accident, because SwiftUI controls write
/// through their bindings as they appear.
@MainActor @Suite struct PresentationInspectorTests {

    private func document(canvas: CGSize) -> EditorDocument {
        let ctx = CGContext(data: nil, width: 1237, height: 641, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1237, height: 641))
        let document = EditorDocument(baseImage: ctx.makeImage()!,
                                      sourceURL: URL(fileURLWithPath: "/tmp/inspector-test.png"))
        document.presentation = Presentation(canvas: .preset(pixelSize: canvas),
                                             background: .solid(.white))
        document.markSaved()
        return document
    }

    private func present(_ document: EditorDocument) {
        let hosting = NSHostingView(rootView: PresentationInspector(document: document))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        window.orderOut(nil)
    }

    /// The size fields carry Custom's own numbers, and a `TextField(value:)`
    /// writes its parsed value back as it appears. Without a guard that write
    /// switched the canvas to Custom just because the panel was opened.
    @Test func openingTheInspectorLeavesThePresetCanvasAlone() {
        let instagram = CGSize(width: 1080, height: 1350)
        let document = document(canvas: instagram)

        present(document)

        #expect(document.presentation?.canvas == .preset(pixelSize: instagram))
        #expect(document.isDirty == false)
    }

    /// Building the panel must not decorate anything: SwiftUI creates
    /// `.inspector` content along with the editor, so a write on appear reached
    /// documents nobody had opened the panel for. The decoration is started by
    /// the toolbar button instead.
    @Test func buildingTheInspectorDecoratesNothing() {
        let ctx = CGContext(data: nil, width: 1200, height: 600, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
        let document = EditorDocument(baseImage: ctx.makeImage()!,
                                      sourceURL: URL(fileURLWithPath: "/tmp/inspector-idle.png"))
        document.markSaved()

        present(document)

        #expect(document.presentation == nil)
        #expect(!document.isDirty)
    }

    /// And what the button does when it opens the panel: a white page with the
    /// picture framed by the default margin, as one undo step.
    @Test func startingADecorationFramesThePicture() {
        let ctx = CGContext(data: nil, width: 1200, height: 600, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
        let document = EditorDocument(baseImage: ctx.makeImage()!,
                                      sourceURL: URL(fileURLWithPath: "/tmp/inspector-start.png"))
        document.markSaved()
        #expect(document.presentation == nil)

        document.startDecorationIfNeeded()

        let presentation = document.presentation
        #expect(presentation != nil)
        let gaps = PresentationLayout.gaps(
            PresentationLayout.resolve(imagePixelSize: document.pixelSize, presentation)
        )
        let expected = Presentation.defaultMargin(for: document.pixelSize)
        #expect(abs(gaps.leading - expected) < 0.5)
        #expect(abs(gaps.trailing - expected) < 0.5)
        #expect(document.undoStack.count == 1)

        // Called again — for instance on a second open — it changes nothing.
        document.startDecorationIfNeeded()
        #expect(document.undoStack.count == 1)
    }

    /// A decoration starts with free margins: the page hugs the picture, so
    /// every one of the four is the user's to set.
    @Test func aNewDecorationStartsWithFreeMargins() {
        let ctx = CGContext(data: nil, width: 1200, height: 600, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
        let document = EditorDocument(baseImage: ctx.makeImage()!,
                                      sourceURL: URL(fileURLWithPath: "/tmp/free.png"))
        document.startDecorationIfNeeded()

        guard case .auto(let margins, let scale)? = document.presentation?.canvas else {
            Issue.record("a new decoration should hug the picture")
            return
        }
        #expect(margins == Presentation.Margins(
            all: Presentation.defaultMargin(for: document.pixelSize)))
        #expect(scale == 1)   // the picture keeps every pixel it had
    }

    /// A number field shows its value as ordinary text and empties itself when
    /// clicked, so typing starts a new number. Selecting the text instead lost
    /// a race with `mouseDown`'s own tracking loop three times over; there is
    /// now nothing to select.
    @Test func clickingANumberFieldEmptiesItForANewValue() async {
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let document = EditorDocument(baseImage: ctx.makeImage()!,
                                      sourceURL: URL(fileURLWithPath: "/tmp/field-focus.png"))
        document.presentation = Presentation(canvas: .auto(margins: .init(all: 20), scale: 1),
                                             background: .solid(.white))

        let hosting = NSHostingView(rootView: PresentationInspector(document: document))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        // Task.sleep, not RunLoop pumping: pumping the run loop in a hosted test
        // starves the very main-queue work being waited on.
        try? await Task.sleep(for: .milliseconds(600))

        // The *number* field, by type rather than by being first: the panel
        // also carries a hex field now, and "the first editable text field"
        // moves whenever the rows are rearranged.
        func firstEditable(_ view: NSView) -> NSTextField? {
            if let field = view as? NumberField.Field, field.isEditable { return field }
            for sub in view.subviews { if let found = firstEditable(sub) { return found } }
            return nil
        }
        guard let field = firstEditable(hosting) else {
            Issue.record("the inspector should have an editable number field")
            return
        }

        // The first number in the panel is the top margin: the page's own size
        // moved to the toolbar's second row with the rest of the canvas
        // controls.
        #expect(field.stringValue == "20")

        // A real mouse-down/up pair: the click is where the problem lived.
        let point = field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        let stamp = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                      modifierFlags: [], timestamp: stamp,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                                    modifierFlags: [], timestamp: stamp,
                                    windowNumber: window.windowNumber, context: nil,
                                    eventNumber: 1, clickCount: 1, pressure: 0)!
        window.postEvent(up, atStart: false)
        window.sendEvent(down)
        try? await Task.sleep(for: .milliseconds(400))

        #expect(field.currentEditor() != nil)   // it took the keyboard
        #expect(field.stringValue.isEmpty)      // and emptied itself

        window.orderOut(nil)
    }

    /// Return has to leave the number you typed on screen. It did reach the
    /// document, but the field repainted itself from the coordinator's copy of
    /// the value — a copy `updateNSView` only refreshes on the *next* pass — so
    /// the old number came straight back and the edit looked rejected.
    @Test func returnKeepsTheTypedNumber() async {
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let document = EditorDocument(baseImage: ctx.makeImage()!,
                                      sourceURL: URL(fileURLWithPath: "/tmp/return.png"))
        document.presentation = Presentation(canvas: .auto(margins: .init(all: 20), scale: 1),
                                             background: .solid(.white))
        let hosting = NSHostingView(rootView: PresentationInspector(document: document))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 1200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(700))

        var fields: [NSTextField] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, field.isEditable { fields.append(field) }
            view.subviews.forEach(walk)
        }
        walk(hosting)
        // The first field showing a margin: the canvas size fields carry the
        // page, 440×340, and every margin is 20.
        guard let field = fields.first(where: { $0.stringValue == "20" }) else {
            Issue.record("the inspector should have a margin field showing 20")
            return
        }

        window.makeFirstResponder(field)
        try? await Task.sleep(for: .milliseconds(200))
        guard let editor = field.currentEditor() as? NSTextView else {
            Issue.record("the field should have taken the keyboard")
            return
        }
        // Typed through the field editor, the way a person types: setting
        // `stringValue` behind its back leaves the cell out of step.
        editor.selectAll(nil)
        editor.insertText("70", replacementRange: editor.selectedRange())
        try? await Task.sleep(for: .milliseconds(100))
        editor.insertNewline(nil)
        try? await Task.sleep(for: .milliseconds(400))

        let gaps = PresentationLayout.gaps(
            PresentationLayout.resolve(imagePixelSize: document.pixelSize, document.presentation))
        #expect(abs(gaps.top - 70) < 0.5)
        #expect(field.stringValue == "70")

        window.orderOut(nil)
    }

    /// A click anywhere else has to end the edit — nothing else in a SwiftUI
    /// panel takes the keyboard when clicked, so the field kept it and the
    /// typed number never reached the document.
    @Test func clickingOutsideTheFieldCommitsAndLetsGo() async {
        let (document, hosting, window) = await inspectorWithMargins()
        guard let field = marginField(in: hosting) else { return }

        window.makeFirstResponder(field)
        try? await Task.sleep(for: .milliseconds(200))
        guard let editor = field.currentEditor() as? NSTextView else {
            Issue.record("the field should have taken the keyboard")
            return
        }
        editor.selectAll(nil)
        editor.insertText("70", replacementRange: editor.selectedRange())
        try? await Task.sleep(for: .milliseconds(100))

        // A click in the panel well away from the field. It goes through the
        // application, not straight to the window: the field watches the app's
        // event stream, which is where a local monitor sees clicks. The mouse-up
        // is queued first so nothing sits in a tracking loop waiting for it.
        let elsewhere = field.convert(CGPoint(x: field.bounds.midX,
                                              y: field.bounds.midY + 220), to: nil)
        let stamp = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: elsewhere,
                                      modifierFlags: [], timestamp: stamp,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: elsewhere,
                                    modifierFlags: [], timestamp: stamp,
                                    windowNumber: window.windowNumber, context: nil,
                                    eventNumber: 1, clickCount: 1, pressure: 0)!
        NSApp.postEvent(up, atStart: false)
        NSApp.postEvent(down, atStart: true)
        try? await Task.sleep(for: .milliseconds(600))

        let gaps = PresentationLayout.gaps(
            PresentationLayout.resolve(imagePixelSize: document.pixelSize, document.presentation))
        #expect(abs(gaps.top - 70) < 0.5)
        #expect(field.currentEditor() == nil)
        #expect(field.stringValue == "70")

        window.orderOut(nil)
    }

    /// Escape is the way out that changes nothing: the document keeps its
    /// number and the field goes back to showing it.
    @Test func escapeLeavesTheNumberAlone() async {
        let (document, hosting, window) = await inspectorWithMargins()
        guard let field = marginField(in: hosting) else { return }

        window.makeFirstResponder(field)
        try? await Task.sleep(for: .milliseconds(200))
        guard let editor = field.currentEditor() as? NSTextView else {
            Issue.record("the field should have taken the keyboard")
            return
        }
        editor.selectAll(nil)
        editor.insertText("70", replacementRange: editor.selectedRange())
        try? await Task.sleep(for: .milliseconds(100))
        // Escape, as the key-binding machinery delivers it: the field editor
        // asks its delegate to handle `cancelOperation:` (the text view itself
        // does not implement it).
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try? await Task.sleep(for: .milliseconds(600))

        let gaps = PresentationLayout.gaps(
            PresentationLayout.resolve(imagePixelSize: document.pixelSize, document.presentation))
        #expect(abs(gaps.top - 20) < 0.5)
        #expect(field.currentEditor() == nil)
        #expect(field.stringValue == "20")

        window.orderOut(nil)
    }

    /// A 400×300 picture with 20 pt margins, shown in a real window: the
    /// keyboard tests all need one.
    private func inspectorWithMargins() async -> (EditorDocument, NSHostingView<PresentationInspector>, NSWindow) {
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let document = EditorDocument(baseImage: ctx.makeImage()!,
                                      sourceURL: URL(fileURLWithPath: "/tmp/keyboard.png"))
        document.presentation = Presentation(canvas: .auto(margins: .init(all: 20), scale: 1),
                                             background: .solid(.white))
        let hosting = NSHostingView(rootView: PresentationInspector(document: document))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 1200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(700))
        return (document, hosting, window)
    }

    /// The first field showing a margin: the canvas size fields carry the page,
    /// 440×340, and every margin is 20.
    private func marginField(in hosting: NSView) -> NSTextField? {
        var fields: [NSTextField] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, field.isEditable { fields.append(field) }
            view.subviews.forEach(walk)
        }
        walk(hosting)
        guard let field = fields.first(where: { $0.stringValue == "20" }) else {
            Issue.record("the inspector should have a margin field showing 20")
            return nil
        }
        return field
    }

    /// Hiding the shadow is not resetting it: the blur and the offset have to
    /// survive, so the button is a way to look at the picture without a shadow
    /// rather than a way to lose one.
    @Test func hidingTheShadowKeepsItForLater() {
        let shadow = Presentation.Shadow(radius: 0.08,
                                         offset: CGPoint(x: 0.01, y: 0.03),
                                         opacity: 0.5)

        let hidden = PresentationInspector.shadowToggled(shadow, remembered: nil)
        #expect(hidden.shadow.opacity == 0)
        #expect(hidden.remembered == shadow)

        let shown = PresentationInspector.shadowToggled(hidden.shadow,
                                                        remembered: hidden.remembered)
        #expect(shown.shadow == shadow)
        #expect(shown.remembered == nil)
    }

    /// A document that never had a shadow has nothing to bring back, and
    /// restoring only the opacity of an all-zero shadow would leave the button
    /// looking dead — zero blur is invisible at any opacity.
    @Test func showingAShadowThatNeverExistedGivesAVisibleOne() {
        let shown = PresentationInspector.shadowToggled(.none, remembered: nil).shadow

        #expect(shown.opacity > 0)
        #expect(shown.radius > 0)
    }

    /// The colour stays out of the round trip: it is the one shadow setting
    /// still worth changing while the shadow is hidden.
    @Test func showingTheShadowKeepsTheColorPickedWhileItWasHidden() {
        let hidden = PresentationInspector.shadowToggled(
            Presentation.Shadow(radius: 0.08, offset: .zero, opacity: 0.4), remembered: nil)
        var recolored = hidden.shadow
        recolored.color = Presentation.Color(red: 0.1, green: 0.2, blue: 0.9, alpha: 1)

        let shown = PresentationInspector.shadowToggled(recolored, remembered: hidden.remembered)

        #expect(shown.shadow.color == recolored.color)
        #expect(shown.shadow.opacity == 0.4)
        #expect(shown.shadow.radius == 0.08)
    }

    /// Every number in an effect row is printed in the unit it is *stored* in,
    /// or converted to one that can be compared with its neighbours.
    ///
    /// Both bugs in this class were reported by hand. The angle was kept in
    /// radians under a label saying degrees, so the field read "1", "2", "3".
    /// The ASCII cell height is a multiple of the cell's width and was printed
    /// as a percentage, so a width of 19 pixels sat beside a height of "160" —
    /// two numbers about one cell that could not be compared.
    @Test func everyEffectParameterIsPrintedInAUsableUnit() {
        let canvas = CGSize(width: 1200, height: 900)
        for kind in Presentation.Effect.Kind.allCases {
            let effect = EffectStack.make(kind, seed: 5)
            for info in EffectStack.parameters(for: kind) {
                let unit = PresentationInspector.unit(for: info, of: effect,
                                                      canvasSize: canvas)
                switch info.parameter {
                case .scale:
                    // A fraction of the short side, shown as the pixels it is.
                    #expect(unit == .pixels(basis: 900), "\(kind).scale")
                case .angle:
                    #expect(unit == .degrees, "\(kind).angle")
                case .detail where kind == .ascii:
                    // A line height, in the same unit as the width it belongs
                    // to: 0.018 × 900 = 16.2 pixels of cell.
                    #expect(unit == .pixels(basis: effect.scale * 900), "ascii.detail")
                case .detail:
                    #expect(unit == (info.step >= 1 ? .count : .percent), "\(kind).detail")
                case .amount, .aberration, .color, .glyphs:
                    #expect(unit == .percent, "\(kind).\(info.parameter)")
                }
            }
        }
    }

    /// Folding a section is a preference, so it has to survive a round trip
    /// through a string in the defaults — and survive whatever it finds there.
    @Test func theFoldedSectionsSurviveTheRoundTrip() {
        typealias Section = PresentationInspector.Section

        #expect(PresentationInspector.sections(
            folded: PresentationInspector.folded(PresentationInspector.foldedByDefault))
            == PresentationInspector.foldedByDefault)

        for sections in [Set<Section>(), Set(Section.allCases), [Section.background]] {
            #expect(PresentationInspector.sections(
                folded: PresentationInspector.folded(sections)) == sections)
        }

        // Always the same spelling for the same set: a value that rewrites
        // itself in a new order every launch reads as a setting that keeps
        // changing.
        #expect(PresentationInspector.folded([.glow, .shadow])
                == PresentationInspector.folded([.shadow, .glow]))

        // A word nobody claims — a section renamed in a later version — leaves
        // that section unfolded rather than throwing the whole preference away.
        #expect(PresentationInspector.sections(folded: "shadow,gloww,,glow")
                == [.shadow, .glow])
        #expect(PresentationInspector.sections(folded: "").isEmpty)
    }

    /// The panel is built once offscreen when the editor opens, so the first
    /// press of the decor button does not pay for it — measured, 140 ms cold
    /// against 80 ms warm, and a primer of plain sliders and fields does not
    /// help because what is slow is the panel's own view types.
    ///
    /// The whole trick rests on the inspector never writing on appear. This is
    /// the test that keeps that true: build it, throw it away, and the document
    /// must not have moved — no presentation conjured, no undo step pushed.
    @Test func warmingTheInspectorLeavesTheDocumentAlone() {
        let ctx = CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let document = EditorDocument(baseImage: ctx.makeImage()!,
                                      sourceURL: URL(fileURLWithPath: "/tmp/warm.png"))
        let before = document.presentation
        let steps = document.undoStack.count

        EditorWindowController.warmDecorInspectorForTesting(document: document)

        #expect(document.presentation == before)
        #expect(document.presentation == nil, "an untouched document must stay undecorated")
        #expect(document.undoStack.count == steps)

        // And a decorated one is left exactly as it was.
        document.startDecorationIfNeeded()
        let decorated = document.presentation
        let decoratedSteps = document.undoStack.count
        EditorWindowController.warmDecorInspectorForTesting(document: document)
        #expect(document.presentation == decorated)
        #expect(document.undoStack.count == decoratedSteps)
    }

    /// The gallery is a shortcut and the palette is a vocabulary; a tile that
    /// is pixel-for-pixel the circle below it makes them read as one list
    /// drawn twice.
    @Test func noPresetRepeatsAPaletteColor() {
        let palette = PresentationInspector.paletteColorsForTesting
        for preset in PresentationInspector.backgroundPresetsForTesting {
            guard case .solid(let color) = preset else { continue }
            #expect(palette.contains(color) == false,
                    "Preset repeats a palette colour: \(color)")
        }
    }
}
