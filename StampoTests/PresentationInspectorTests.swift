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
}
