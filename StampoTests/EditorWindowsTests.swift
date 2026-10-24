import AppKit
import SwiftUI
import Testing
@testable import Stampo

@MainActor private final class EditorMinimumSizes {
    var widths: [CGFloat] = []
}

/// A window per document: the editor used to be one window that swapped its
/// contents, so a second screenshot could not be opened until the first was
/// settled — the editor locked the capture behind whatever was already in it.
@MainActor @Suite(.serialized) struct EditorWindowsTests {

    private func writePNG(_ name: String, width: Int = 40, height: Int = 30) throws -> URL {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    @Test func twoShotsOpenTwoWindowsAndTheSameShotComesForward() throws {
        EditorWindowController.closeAllForTesting()
        let first = try writePNG("editor-windows-first.png")
        let second = try writePNG("editor-windows-second.png")
        defer {
            EditorWindowController.closeAllForTesting()
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        EditorWindowController.open(url: first)
        #expect(EditorWindowController.openCount == 1)

        // The point of the whole change: the second shot does not have to wait
        // for the first to be settled.
        EditorWindowController.open(url: second)
        #expect(EditorWindowController.openCount == 2)

        // One window per file, though: opening the same shot again brings its
        // editor forward rather than starting a second race to save over it.
        EditorWindowController.open(url: first)
        #expect(EditorWindowController.openCount == 2)
    }

    /// A file that cannot be read leaves nothing behind — no empty editor in
    /// the list, and nothing for the next question about unsaved work to walk
    /// into.
    @Test func aFileThatCannotBeReadOpensNothing() {
        EditorWindowController.closeAllForTesting()
        defer { EditorWindowController.closeAllForTesting() }
        let missing = URL(fileURLWithPath: "/nonexistent/editor-windows-ghost.png")
        EditorWindowController.open(url: missing)
        #expect(EditorWindowController.openCount == 0)
    }

    /// With nothing dirty the question passes straight through, however many
    /// windows are open — it is asked before quitting and before the
    /// first-launch window takes the screen.
    @Test func cleanEditorsNeverStandInTheWay() throws {
        EditorWindowController.closeAllForTesting()
        let url = try writePNG("editor-windows-clean.png")
        defer {
            EditorWindowController.closeAllForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        EditorWindowController.open(url: url)
        #expect(EditorWindowController.confirmDiscardingUnsavedWork(afterSave: {}))
    }

    /// The outer hosting controller must still hand every toolbar item to the
    /// window when the canvas moves into nested hosting controllers.
    @Test func arcToolbarKeepsControlsAndWindowFrame() async throws {
        guard #available(macOS 26, *) else { return }
        let restore = configureArc(false)
        let url = try writePNG("editor-arc-toolbar.png", width: 1600, height: 800)
        defer {
            EditorWindowController.closeAllForTesting()
            restore()
            try? FileManager.default.removeItem(at: url)
        }

        let legacy = try await openWindow(url)
        let controls = try toolbarControls(in: legacy)
        #expect(controls.count > 8, "the baseline must contain the editor's toolbar controls")
        EditorWindowController.closeAllForTesting()

        AppSettings.store.set(true, forKey: AppSettings.Keys.editorArcFrame)
        let window = try await openWindow(url)
        #expect(try toolbarControls(in: window) == controls,
                "nested hosting changed the editor's actual toolbar controls")
        let split = try #require(frameSplit(in: window))
        #expect(window.contentMinSize.width == 1140)
        #expect(window.contentMinSize.height == EditorView.minimumContentSize.height)
        #expect(split.panelItem.isCollapsed)
        // Opposite requests in the same turn must cancel the queued opening.
        split.setPresented(true)
        split.setPresented(false)
        await settle(window)
        #expect(split.panelItem.isCollapsed)
        AppSettings.store.set(false, forKey: AppSettings.Keys.editorArcFrame)
        window.setContentSize(NSSize(width: 1140, height: 720))
        await settle(window)
        let frame = window.frame

        for presented in [true, false, true] {
            try pressDecor(in: window)
            await settle(window)
            #expect(split.panelItem.isCollapsed == !presented)
            #expect(window.frame == frame, "Decor moved or resized the Arc editor")
            #expect(window.contentMinSize.width == 1140)
            print("ARC toggle presented=\(presented) window=\(window.frame)")
        }

        // AppKit can collapse an item while dragging. Its next toolbar press
        // must reopen it, proving the state made the trip back into SwiftUI.
        split.panelItem.isCollapsed = true
        await settle(window)
        #expect(split.panelItem.isCollapsed, "a native collapse must survive SwiftUI layout")
        try pressDecor(in: window)
        await settle(window)
        #expect(!split.panelItem.isCollapsed)
        #expect(window.frame == frame)
    }

    /// Retained evidence uses the real editor and its own image reporter. It
    /// does not need Screen Recording permission or alter canvas geometry.
    @Test func arcLayoutAndFocusEvidence() async throws {
        guard #available(macOS 26, *) else { return }
        let restore = configureArc(true)
        let url = try writePNG("editor-arc-layout.png", width: 1600, height: 800)
        defer {
            EditorWindowController.closeAllForTesting()
            restore()
            try? FileManager.default.removeItem(at: url)
        }

        for size in [NSSize(width: 1140, height: 720), NSSize(width: 1280, height: 780)] {
            let window = try await openWindow(url)
            let split = try #require(frameSplit(in: window))
            window.setFrame(NSRect(origin: NSPoint(x: 10, y: 10), size: size), display: true)
            await settle(window)
            try pressDecor(in: window)
            await settle(window)
            #expect(abs(split.splitView.arrangedSubviews[0].frame.width - 320) < 0.5)
            let panel = split.splitView.arrangedSubviews[0].frame
            let detail = split.splitView.arrangedSubviews[1].frame
            #expect(abs(panel.width + 8 + detail.width - size.width) < 0.5)
            #expect(split.splitView.dividerThickness == 8)
            print("ARC initial content=\(size) panel=\(panel) detail=\(detail) window=\(window.frame)")

            // Closing after the first Decor press keeps presentation identical
            // on both sides of the fitted-image measurement.
            try pressDecor(in: window)
            await settle(window)
            let closedImage = try imageRect(in: split, window: window)
            let closedDetail = split.detailHosting.view.bounds
            #expect(abs(closedDetail.width - size.width) < 0.5)
            try pressDecor(in: window)
            await settle(window)
            let openImage = try imageRect(in: split, window: window)
            let openDetail = split.detailHosting.view.bounds
            #expect(openImage.width < closedImage.width)
            #expect(abs(openImage.height - closedImage.height
                        * openImage.width / closedImage.width) < 1,
                    "fit should preserve proportions within the reporter's pixel rounding")
            #expect(abs(openImage.midY - closedImage.midY) < 0.5)
            let detailScreen = window.convertToScreen(
                split.detailHosting.view.convert(openDetail, to: nil))
            #expect(abs(openImage.midX - detailScreen.midX) < 0.5)
            for _ in 0..<2 {
                await settle(window)
                #expect(try imageRect(in: split, window: window) == openImage,
                        "the fitted image changed after another layout cycle")
            }
            print("ARC fit content=\(size) closedImage=\(closedImage) openImage=\(openImage) closedDetail=\(closedDetail) openDetail=\(openDetail)")

            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
            await settle(window)
            #expect(window.isKeyWindow)
            #expect(EditorWindowController.keyEditor != nil)
            let fields = views(in: split.panelHosting.view).compactMap { $0 as? NSTextField }
            let color = LocaleManager.shared.string("Color")
            let hex = try #require(fields.first {
                $0.isEditable && ($0.accessibilityLabel() == color || $0.stringValue.hasPrefix("#"))
            }, "the actual inspector should expose its editable color field")
            #expect(window.makeFirstResponder(hex))
            await settle(window)
            #expect(hex.currentEditor() != nil)
            #expect(window.isKeyWindow)
            #expect(window.makeFirstResponder(nil))
            await settle(window)
            #expect(hex.currentEditor() == nil)
            print("ARC focus content=\(size) key=\(window.isKeyWindow) hex=\(hex.stringValue) released=\(hex.currentEditor() == nil)")

            for (name, appearance) in [("light", NSAppearance.Name.aqua),
                                       ("dark", NSAppearance.Name.darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                await settle(window)
                try cacheEditor(window, name: "arc-\(Int(size.width))-\(name)")
            }

            split.splitView.setPosition(400, ofDividerAt: 0)
            print("ARC drag immediate=\(split.splitView.arrangedSubviews.map(\.frame)) min=\(split.splitView.minPossiblePositionOfDivider(at: 0)) max=\(split.splitView.maxPossiblePositionOfDivider(at: 0))")
            await settle(window)
            let expected: CGFloat = size.width == 1140 ? 345 : 400
            #expect(abs(split.splitView.arrangedSubviews[0].frame.width - expected) < 0.5)
            #expect(split.splitView.arrangedSubviews[1].frame.width >= 787)
            print("ARC drag content=\(size) panel=\(split.splitView.arrangedSubviews[0].frame) detail=\(split.splitView.arrangedSubviews[1].frame)")

            if size.width == 1140 {
                window.setContentSize(NSSize(width: 1280, height: size.height))
                await settle(window)
                #expect(abs(split.splitView.arrangedSubviews[0].frame.width - expected) < 0.5,
                        "resizing the window should preserve the panel width")
            }
            EditorWindowController.closeAllForTesting()
        }
    }

    @Test func arcTabbedWindowsKeepTheirOwnContainers() async throws {
        guard #available(macOS 26, *) else { return }
        let restore = configureArc(true)
        let firstURL = try writePNG("editor-arc-tab-first.png")
        let secondURL = try writePNG("editor-arc-tab-second.png")
        defer {
            EditorWindowController.closeAllForTesting()
            restore()
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let first = try await openWindow(firstURL)
        let firstSplit = try #require(frameSplit(in: first))
        let second = try await openWindow(secondURL)
        let secondSplit = try #require(frameSplit(in: second))
        #expect(firstSplit !== secondSplit)
        #expect(first.tabbingIdentifier == "StampoEditor")
        #expect(second.tabbingIdentifier == "StampoEditor")
        first.addTabbedWindow(second, ordered: .above)
        await settle(second)
        #expect(first.tabbedWindows?.contains(second) == true)
        first.close()
        await settle(second)
        #expect(EditorWindowController.openCount == 1)
        #expect(frameSplit(in: second) === secondSplit)
        #expect(second.contentView != nil)
        print("ARC tabs independent=true survivingWindow=\(second.frame) count=\(EditorWindowController.openCount)")
    }

    @Test func disablingArcKeepsTheNativeInspectorsWindowMinimum() async throws {
        guard #available(macOS 26, *) else { return }
        let restore = configureArc(false)
        let url = try writePNG("editor-arc-disabled.png")
        defer {
            EditorWindowController.closeAllForTesting()
            restore()
            try? FileManager.default.removeItem(at: url)
        }
        AppSettings.store.removeObject(forKey: AppSettings.Keys.editorArcFrame)
        #expect(AppSettings.editorArcFrame == false)
        #expect(EditorView.usesArcFrame == false)
        let window = try await openWindow(url)
        #expect(frameSplit(in: window) == nil)
        #expect(window.contentMinSize == EditorView.minimumContentSize)
        let minimums = EditorMinimumSizes()
        let observation = window.observe(\.contentMinSize, options: [.new]) { _, change in
            let width = change.newValue?.width
            MainActor.assumeIsolated {
                if let width { minimums.widths.append(width) }
            }
        }
        defer { observation.invalidate() }
        window.setContentSize(NSSize(width: 900, height: 720))
        await settle(window)
        try pressDecor(in: window)
        await settle(window)
        // The exact base also closes its native inspector again during this
        // synthetic click. Check the size policy as it is applied, including
        // the expansion, rather than asserting the native host's final state.
        #expect(minimums.widths.contains(1220))
        #expect(window.contentView!.bounds.width >= 1220)
        let opened = window.frame
        try pressDecor(in: window)
        await settle(window)
        #expect(minimums.widths.contains(900))
        #expect(window.frame == opened)
        print("ARC disabled minimums=\(minimums.widths) final=\(window.contentMinSize) openedWindow=\(opened)")
    }

    /// A selected annotation makes the canvas's actual local key monitor
    /// observable without exposing private tool state or adding a test hook.
    @Test func arcCanvasKeyboardStaysInItsWindow() async throws {
        guard #available(macOS 26, *) else { return }
        let restore = configureArc(true)
        defer { restore() }
        let document = EditorDocument(
            baseImage: TestImages.make(width: 1600, height: 800),
            sourceURL: URL(fileURLWithPath: "/tmp/editor-arc-keyboard.png"))
        let annotation = Annotation(kind: .rect, start: CGPoint(x: 20, y: 20),
                                    end: CGPoint(x: 60, y: 60), color: .red, lineWidth: 4)
        document.beginChange()
        document.annotations.append(annotation)
        document.commitChange()
        document.selectedID = annotation.id

        weak var editorWindow: NSWindow?
        let context = EditorWindowContext(
            isKeyWindow: { editorWindow?.isKeyWindow == true },
            overlayParent: { editorWindow })
        let hosting = NSHostingController(rootView: EditorView(
            document: document, windowContext: context, arcFrame: true).managedLocale())
        hosting.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: hosting)
        editorWindow = window
        window.isReleasedWhenClosed = false
        window.styleMask = [.titled, .closable, .resizable]
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 1140, height: 720))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        await settle(window)
        try pressDecor(in: window)
        await settle(window)
        let split = try #require(frameSplit(in: window))
        #expect(!split.panelItem.isCollapsed)
        #expect(context.isKeyWindow())
        #expect(context.overlayParent() === window)
        #expect(document.selectedID == annotation.id)

        func postKey(_ code: UInt16, characters: String) throws {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = try #require(NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code))
                NSApp.postEvent(event, atStart: false)
            }
        }

        #expect(window.makeFirstResponder(nil))
        try postKey(124, characters: "\u{F703}")
        await settle(window)
        #expect(document.annotations[0].start.x == 21,
                "the open panel must not take the canvas's arrow shortcut")

        let color = LocaleManager.shared.string("Color")
        let fields = views(in: split.panelHosting.view).compactMap { $0 as? NSTextField }
        let hex = try #require(fields.first {
            $0.isEditable && ($0.accessibilityLabel() == color || $0.stringValue.hasPrefix("#"))
        })
        #expect(window.makeFirstResponder(hex))
        await settle(window)
        let fieldEditor = try #require(hex.currentEditor() as? NSTextView)
        fieldEditor.selectAll(nil)
        try postKey(3, characters: "F")
        await settle(window)
        #expect(fieldEditor.string == "F", "typed text must reach the inspector's field editor")
        try postKey(124, characters: "\u{F703}")
        await settle(window)
        #expect(document.annotations[0].start.x == 21,
                "an arrow in the color field must not nudge the annotation")
        #expect(context.isKeyWindow())

        #expect(window.makeFirstResponder(nil))
        await settle(window)
        #expect(hex.currentEditor() == nil)
        try postKey(124, characters: "\u{F703}")
        await settle(window)
        #expect(document.annotations[0].start.x == 22,
                "the canvas must receive arrows again after the field releases focus")
        print("ARC keyboard key=\(context.isKeyWindow()) annotationX=\(document.annotations[0].start.x) typed=F fieldReleased=\(hex.currentEditor() == nil)")
    }

    // MARK: Real-window harness

    private func configureArc(_ enabled: Bool) -> () -> Void {
        EditorWindowController.closeAllForTesting()
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        let keys = [AppSettings.Keys.editorArcFrame, AppSettings.Keys.editorSystemToolbar,
                    AppSettings.Keys.decorFoldedSections]
        let held = keys.map { ($0, AppSettings.store.object(forKey: $0)) }
        AppSettings.store.set(enabled, forKey: AppSettings.Keys.editorArcFrame)
        AppSettings.store.set(true, forKey: AppSettings.Keys.editorSystemToolbar)
        AppSettings.store.set(PresentationInspector.folded(PresentationInspector.foldedByDefault),
                              forKey: AppSettings.Keys.decorFoldedSections)
        return {
            NSApp.setActivationPolicy(policy)
            for (key, value) in held {
                if let value { AppSettings.store.set(value, forKey: key) }
                else { AppSettings.store.removeObject(forKey: key) }
            }
        }
    }

    private func openWindow(_ url: URL) async throws -> NSWindow {
        EditorWindowController.open(url: url)
        let window = try #require(NSApp.windows.first {
            $0.isVisible && $0.title == url.lastPathComponent
        })
        await settle(window)
        return window
    }

    private func settle(_ window: NSWindow) async {
        for _ in 0..<4 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(180))
        }
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func views(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { views(in: $0) }
    }

    private func frameSplit(in window: NSWindow) -> FrameSplitController? {
        guard let content = window.contentView else { return nil }
        // A representable's controller is managed by SwiftUI, which need not
        // expose it through the outer hosting controller's children array.
        return views(in: content).compactMap {
            ($0 as? FrameSplitView)?.delegate as? FrameSplitController
        }.first
    }

    private func toolbarControls(in window: NSWindow) throws -> [String] {
        let toolbar = try #require(window.toolbar, "the editor must have a native toolbar")
        func labels(_ item: NSToolbarItem) -> [String] {
            let own = "\(item.label)|\(item.paletteLabel)|\(item.toolTip ?? "")"
            return [own] + ((item as? NSToolbarItemGroup)?.subitems.flatMap(labels) ?? [])
        }
        let controls = toolbar.items.flatMap(labels)
        print("ARC toolbar \(controls)")
        return controls
    }

    private func pressDecor(in window: NSWindow) throws {
        let title = LocaleManager.shared.string("Decor")
        let view = try #require(window.toolbar?.items.first(where: { $0.label == title })?.view,
                                "the actual native toolbar must expose Decor")
        #expect(view.bounds.width > 0 && view.bounds.height > 0)
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let stamp = ProcessInfo.processInfo.systemUptime
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: stamp,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: stamp,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0))
        window.postEvent(up, atStart: false)
        window.sendEvent(down)
    }

    private func imageRect(in split: FrameSplitController, window: NSWindow) throws -> NSRect {
        let reporter = try #require(views(in: split.detailHosting.view).first {
            $0 is ImageScreenFrameReporter.ReporterView
        }, "the canvas must contain its actual image reporter")
        return window.convertToScreen(reporter.convert(reporter.bounds, to: nil))
    }

    private func cacheEditor(_ window: NSWindow, name: String) throws {
        let hosting = try #require(window.contentView)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        let opaque = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        opaque.size = hosting.bounds.size
        let context = try #require(NSGraphicsContext(bitmapImageRep: opaque))
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            // Hosting views are transparent over the window. Include that
            // backing in the PNG, otherwise transparent pixels appear black.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: opaque.size).fill()
            let image = NSImage(size: opaque.size)
            image.addRepresentation(bitmap)
            image.draw(in: NSRect(origin: .zero, size: opaque.size), from: .zero,
                       operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
        let data = try #require(opaque.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: Probe.folder, withIntermediateDirectories: true)
        let url = Probe.folder.appendingPathComponent("\(name).png")
        try data.write(to: url)
        print("PROBE \(url.path)")
    }
}
