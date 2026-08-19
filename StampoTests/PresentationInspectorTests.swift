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
        #expect(abs(gaps.leading - Presentation.defaultMargin) < 0.5)
        #expect(abs(gaps.trailing - Presentation.defaultMargin) < 0.5)
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
        #expect(margins == Presentation.Margins(all: Presentation.defaultMargin))
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

        func firstEditable(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            for sub in view.subviews { if let found = firstEditable(sub) { return found } }
            return nil
        }
        guard let field = firstEditable(hosting) else {
            Issue.record("the inspector should have an editable number field")
            return
        }

        #expect(field.stringValue == "440")   // 400 wide picture + 20 either side

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
}
