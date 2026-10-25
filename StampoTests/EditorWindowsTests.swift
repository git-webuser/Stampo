import AppKit
import SwiftUI
import Testing
@testable import Stampo

@MainActor private final class EditorMinimumSizes {
    var widths: [CGFloat] = []
}

@MainActor private final class EditorScreenWidth {
    var value: CGFloat = 1140
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
        #expect(window.contentMinSize.width == arcMinimumWidth(of: window))
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
            #expect(window.contentMinSize.width == arcMinimumWidth(of: window))
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
            // Positions are whole backing pixels: half a point on a 2x screen,
            // a whole point on the 1x display of a CI runner.
            let pixel = max(0.5, 1 / window.backingScaleFactor)
            let split = try #require(frameSplit(in: window))
            window.setFrame(NSRect(origin: NSPoint(x: 10, y: 10), size: size), display: true)
            await settle(window)
            try pressDecor(in: window)
            await settle(window)
            #expect(abs(split.splitView.arrangedSubviews[0].frame.width - 320) <= pixel)
            let panel = split.splitView.arrangedSubviews[0].frame
            let detail = split.splitView.arrangedSubviews[1].frame
            #expect(abs(panel.width + 8 + detail.width - size.width) <= pixel)
            #expect(split.splitView.dividerThickness == 8)
            print("ARC initial content=\(size) panel=\(panel) detail=\(detail) window=\(window.frame)")

            // Closing after the first Decor press keeps presentation identical
            // on both sides of the fitted-image measurement.
            try pressDecor(in: window)
            await settle(window)
            let closedImage = try imageRect(in: split, window: window)
            let closedDetail = split.detailHosting.view.bounds
            #expect(abs(closedDetail.width - (size.width - 8)) <= pixel)
            try pressDecor(in: window)
            await settle(window)
            let openImage = try imageRect(in: split, window: window)
            let openDetail = split.detailHosting.view.bounds
            #expect(openImage.width < closedImage.width)
            // The reporter rounds each side to whole points: 864 x 432 fits to
            // 682 x 342 on a 1x runner, where proportion says 341.
            #expect(abs(openImage.height - closedImage.height
                        * openImage.width / closedImage.width) <= max(1, pixel),
                    "fit should preserve proportions within the reporter's pixel rounding")
            #expect(abs(openImage.midY - closedImage.midY) <= pixel)
            let detailScreen = window.convertToScreen(
                split.detailHosting.view.convert(openDetail, to: nil))
            let cardMidX = detailScreen.midX - ArcFrameLayout.frameGap / 2
            #expect(abs(openImage.midX - cardMidX) <= pixel,
                    "fit must centre in the card after its trailing frame inset")
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
            #expect(abs(split.splitView.arrangedSubviews[0].frame.width - expected) <= pixel)
            #expect(split.splitView.arrangedSubviews[1].frame.width >= 787)
            print("ARC drag content=\(size) panel=\(split.splitView.arrangedSubviews[0].frame) detail=\(split.splitView.arrangedSubviews[1].frame)")

            if size.width == 1140 {
                window.setContentSize(NSSize(width: 1280, height: size.height))
                await settle(window)
                #expect(abs(split.splitView.arrangedSubviews[0].frame.width - expected) <= pixel,
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

    /// A mutation of the divider or the inspector caller must change pixels
    /// and real control positions here, not merely another layout constant.
    @Test func arcChromeUsesOneEightPointFrameInBothAppearances() async throws {
        guard #available(macOS 26, *) else { return }
        let restore = configureArc(true)
        let url = try writePNG("editor-arc-chrome.png", width: 1600, height: 800)
        defer {
            EditorWindowController.closeAllForTesting()
            restore()
            try? FileManager.default.removeItem(at: url)
        }
        for size in [NSSize(width: 1140, height: 720), NSSize(width: 1280, height: 780)] {
            for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let window = try await openWindow(url)
                window.appearance = NSAppearance(named: appearance)
                window.setFrame(NSRect(origin: NSPoint(x: 10, y: 10), size: size), display: true)
                await settle(window)
                let split = try #require(frameSplit(in: window))
                let originalFrame = window.frame
                // The display decides how much of the requested size the window
                // gets: a CI runner's screen is 677pt tall, so 720 comes back as
                // 677. Every edge is measured against the window as it is.
                let actual = originalFrame.size
                // Opening starts the real decoration. Use that same document
                // presentation for the closed and open captures.
                try pressDecor(in: window)
                await settle(window)
                try pressDecor(in: window)
                await settle(window)
                for open in [false, true] {
                    if split.panelItem.isCollapsed == open {
                        try pressDecor(in: window)
                        await settle(window)
                    }
                    let name = "chrome-\(Int(size.width))-\(theme)-\(open ? "open" : "closed")"
                    let evidence = try ArcChromeEvidence.chrome(window, split: split, name: name, open: open)
                    let expectedX: CGFloat = open ? 328 : 8
                    let expectedWidth = actual.width - (open ? 336 : 16)
                    #expect(abs(evidence.card.minX - expectedX) <= 1,
                            "the painted card's left edge lost its 8pt frame")
                    #expect(abs(evidence.card.width - expectedWidth) <= 1,
                            "the painted card has the wrong width")
                    #expect(abs(evidence.card.maxX - (actual.width - 8)) <= 1)
                    #expect(abs(evidence.card.maxY - (actual.height - 8)) <= 1,
                            "the painted card must retain its bottom frame")
                    #expect(window.frame == originalFrame, "opening Decor must not move or resize the window")
                    if open {
                        let inset = try #require(evidence.headerInset,
                                                "the real inspector's first header is required to measure outer padding")
                        #expect(abs(inset - 8) <= 1,
                                "the Arc inspector caller fell back to the legacy 16pt padding")
                        let top = try #require(evidence.headerTopInset)
                        let headerGap = try #require(evidence.capsuleToHeader)
                        #expect(abs(top - 6) <= 0.5,
                                "the panel adds 6pt, not the toolbar's gap a second time and not 0")
                        #expect(abs(headerGap - 14) <= 2,
                                "capsule to first inspector header is the toolbar's 8pt plus the panel's 6")
                    }
                    let cardGap = try #require(evidence.capsuleToCard)
                    #expect(abs(cardGap - 8) <= 1)
                    #expect(evidence.cornerMaxDelta <= 3, "card corners must not cast rectangular shadows")
                    let rowHeight = try #require(evidence.markupHeight)
                    #expect(abs(rowHeight - 40) <= 1)
                    let reference = try #require(evidence.frameColors.first)
                    #expect(evidence.frameColors.allSatisfy { ArcChromeEvidence.delta($0, reference) <= 3 },
                            "panel, toolbar strip and outer frame do not share their backing color")
                    #expect(ArcChromeEvidence.delta(evidence.cardColor, reference) >= 8,
                            "the white card does not separate from the frame in this appearance")
                }
                EditorWindowController.closeAllForTesting()
            }
        }

        // The brief also names an 884pt card for the still-unadapted Text
        // row. Its explicit 320+8+8 frame geometry requires a 1220pt window.
        let textWindow = try await openWindow(url)
        textWindow.appearance = NSAppearance(named: .aqua)
        textWindow.setFrame(NSRect(x: 10, y: 10, width: 1220, height: 720), display: true)
        await settle(textWindow)
        try pressDecor(in: textWindow)
        await settle(textWindow)
        #expect(textWindow.makeFirstResponder(nil))
        let textShortcut = try #require(EditorTool.text.shortcut)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: textWindow.windowNumber, context: nil,
                characters: "t", charactersIgnoringModifiers: "t", isARepeat: false,
                keyCode: textShortcut.keyCode))
            NSApp.postEvent(event, atStart: false)
        }
        await settle(textWindow)
        let textSplit = try #require(frameSplit(in: textWindow))
        let segments = views(in: textSplit.detailHosting.view).compactMap { $0 as? NSSegmentedControl }
        #expect(segments.contains { $0.segmentCount == TextStyleFlag.allCases.count },
                "the real Text row must expose its five format segments")
        let textEvidence = try ArcChromeEvidence.chrome(
            textWindow, split: textSplit, name: "chrome-text-884-light", open: true)
        #expect(abs(textEvidence.card.width - 884) <= 1)
        print("ARC TEXT cardWidth=\(textEvidence.card.width) segmentCounts=\(segments.map(\.segmentCount)); width adaptation is intentionally deferred to S3")
    }

    /// Exercise the window's one actual minimum-size policy with a narrow
    /// display width. A correct property alone is insufficient if SwiftUI's
    /// root still insists on 1140 and makes the real split wider than the window.
    @Test func arcWindowMinimumReallyFitsANarrowScreen() async throws {
        guard #available(macOS 26, *) else { return }
        let restore = configureArc(true)
        let document = EditorDocument(baseImage: TestImages.make(width: 1600, height: 800),
                                      sourceURL: URL(fileURLWithPath: "/tmp/editor-arc-narrow-screen.png"))
        let screenWidth = EditorScreenWidth()
        weak var editorWindow: NSWindow?
        let context = EditorWindowContext(isKeyWindow: { editorWindow?.isKeyWindow == true },
                                          overlayParent: { editorWindow })
        let hosting = NSHostingController(rootView: EditorView(
            document: document, windowContext: context, arcFrame: true,
            arcMinimumWidth: 1140, visibleScreenWidth: { _ in screenWidth.value }).managedLocale())
        hosting.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: hosting)
        editorWindow = window
        window.isReleasedWhenClosed = false
        window.styleMask = [.titled, .closable, .resizable]
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.contentMinSize = NSSize(width: 1140, height: 360)
        window.setContentSize(NSSize(width: 1140, height: 640))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await settle(window)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            restore()
        }
        screenWidth.value = 1024
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        await settle(window)
        window.setContentSize(NSSize(width: 1024, height: 640))
        await settle(window)
        let content = try #require(window.contentView)
        let split = try #require(frameSplit(in: window))
        print("ARC NARROW requested=1024 contentMin=\(window.contentMinSize) content=\(content.bounds) split=\(split.splitView.bounds) window=\(window.frame)")
        try ArcChromeEvidence.writeJSON([
            "requestedScreenWidth": 1024, "contentMinWidth": window.contentMinSize.width,
            "content": ArcChromeEvidence.rectJSON(content.bounds),
            "split": ArcChromeEvidence.rectJSON(split.splitView.bounds),
            "window": ArcChromeEvidence.rectJSON(window.frame)
        ], name: "narrow-screen")
        #expect(abs(window.contentMinSize.width - 1024) <= 0.5)
        #expect(abs(content.bounds.width - 1024) <= 0.5,
                "the editor cannot actually fit the narrow-screen minimum")
        #expect(abs(split.splitView.bounds.width - 1024) <= 0.5,
                "a duplicate SwiftUI floor made the split overflow its narrow window")
        let frame = window.frame
        try pressDecor(in: window)
        await settle(window)
        #expect(window.frame == frame, "opening the panel moved the editor on a narrow screen")
        print("ARC NARROW open panel=\(split.splitView.arrangedSubviews[0].frame) detail=\(split.splitView.arrangedSubviews[1].frame)")
        screenWidth.value = 1470
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        await settle(window)
        #expect(window.contentMinSize.width == 1140)
        print("ARC NARROW restored contentMin=\(window.contentMinSize) split=\(split.splitView.bounds)")
    }

    @Test func legacyInspectorKeepsSixteenPointInsets() {
        let document = EditorDocument(baseImage: TestImages.make(width: 300, height: 200),
                                      sourceURL: URL(fileURLWithPath: "/tmp/arc-default-inspector.png"))
        let inspector = PresentationInspector(document: document)
        #expect(inspector.contentInsets.top == 16)
        #expect(inspector.contentInsets.leading == 16)
        #expect(inspector.contentInsets.bottom == 16)
        #expect(inspector.contentInsets.trailing == 16)
    }

    /// The catalogue test proves the words; this is the real 320pt panel with
    /// the real tile layout. The label and its available frame are retained
    /// alongside the rendered glyphs so truncation cannot be inferred away.
    @Test func arcBackgroundLabelsFitAt320InEnglishAndRussian() async throws {
        let document = EditorDocument(baseImage: TestImages.make(width: 1600, height: 800),
                                      sourceURL: URL(fileURLWithPath: "/tmp/arc-label-panel.png"))
        document.startDecorationIfNeeded()
        let key = AppSettings.Keys.decorFoldedSections
        let held = AppSettings.store.object(forKey: key)
        AppSettings.store.set(PresentationInspector.folded(PresentationInspector.foldedByDefault), forKey: key)
        defer {
            if let held { AppSettings.store.set(held, forKey: key) }
            else { AppSettings.store.removeObject(forKey: key) }
        }
        for (language, label) in [("en", "None"), ("ru", "Без фона")] {
            let host = NSHostingView(rootView: PresentationInspector(
                document: document, contentInsets: ArcFrameLayout.panelContentInsets)
                .environment(\.locale, Locale(identifier: language)))
            let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 320, height: 740),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = ArcFrameLayout.frameColor
            window.contentView = host
            window.orderFrontRegardless()
            await settle(window)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            let capture = try ArcChromeEvidence.capture(window, name: "panel-320-\(language)")
            let text = try ArcChromeEvidence.recognizedText(capture)
            let focusViews = ArcChromeEvidence.views(in: host).filter {
                !$0.isHiddenOrHasHiddenAncestor && String(describing: type(of: $0)) == "_FocusRingView"
            }
            let focusFrames: [NSRect] = focusViews.map { capture.topRect($0) }
            let tiles = focusFrames.filter {
                $0.width >= 60 && $0.width <= 75 && $0.height >= 65 && $0.height <= 80
            }
            let firstRowY = try #require(tiles.map(\.minY).min())
            let firstRow = tiles.filter { abs($0.minY - firstRowY) <= 2 }
            #expect(firstRow.count == 4, "the real panel must retain four background columns")
            let tile = try #require(firstRow.max { $0.minX < $1.minX })
            let match = try #require(text.first {
                tile.contains(NSPoint(x: $0.frame.midX, y: $0.frame.midY))
            }, "the fourth tile must contain rendered caption pixels")
            let available = tile.width - 10
            // The ink's edge sits on the 4pt line exactly, and recognition at 1x
            // reports boxes in whole points that land a hair past it (a CI
            // runner measured 286.0000009 against 286). One backing pixel of
            // slack at 1x; none where the screen is 2x and the box is exact.
            let slack: CGFloat = window.backingScaleFactor >= 2 ? 0 : 1
            let captionBounds = tile.insetBy(dx: 4 - slack, dy: 4 - slack)
            #expect(captionBounds.contains(match.frame),
                    "the complete caption ink must fit inside the tile's existing 5pt padding")
            let natural = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
            // OCR is retained for its ink bounds, not as a second catalogue:
            // at 11pt it can mistake Russian glyphs even in a complete label.
            print("ARC LABEL language=\(language) label=\(label) ocr=\(match.text) ink=\(match.frame) tile=\(tile) naturalWidth=\(natural) available=\(available) minimumScale=0.8")
            #expect(available > 0)
            #expect(natural * 0.8 <= available + 1,
                    "the full label cannot fit even at the tile's existing minimum scale")
            try ArcChromeEvidence.writeJSON([
                "language": language, "label": label, "ocrText": match.text,
                "frame": ArcChromeEvidence.rectJSON(match.frame),
                "tileFrame": ArcChromeEvidence.rectJSON(tile),
                "naturalWidth": natural, "minimumScale": 0.8, "availableWidth": available
            ], name: "panel-label-\(language)")
        }
    }

    /// Both paths start closed and measure the exposed panel at 8ms intervals.
    /// No preloading is introduced by this test.
    @Test func arcAndLegacyDecorOpeningLatency() async throws {
        guard #available(macOS 26, *) else { return }
        let restore = configureArc(false)
        let url = try writePNG("editor-arc-opening-latency.png", width: 1600, height: 800)
        defer {
            EditorWindowController.closeAllForTesting()
            restore()
            try? FileManager.default.removeItem(at: url)
        }
        for arc in [false, true] {
            AppSettings.store.set(arc, forKey: AppSettings.Keys.editorArcFrame)
            let openedAt = ProcessInfo.processInfo.systemUptime
            EditorWindowController.open(url: url)
            let window = try #require(NSApp.windows.first { $0.isVisible && $0.title == url.lastPathComponent })
            window.contentView?.layoutSubtreeIfNeeded()
            let openCost = (ProcessInfo.processInfo.systemUptime - openedAt) * 1000
            window.setFrame(NSRect(x: 10, y: 10, width: 1280, height: 780), display: true)
            await settle(window)
            let mode = arc ? "arc" : "legacy"
            for attempt in ["first", "repeat"] {
                let recorder = ArcOpeningRecorder(window: window, arcSplit: frameSplit(in: window))
                try #require(!recorder.panelPresented, "each latency sample must start with Decor closed")
                let initialWidth = recorder.panelWidth
                #expect(initialWidth <= 0.5)
                recorder.start()
                try pressDecor(in: window)
                recorder.sample()
                try await Task.sleep(for: .milliseconds(1200))
                recorder.stop()
                try ArcChromeEvidence.writeJSON([
                    "mode": mode, "attempt": attempt, "openCallAndFirstLayoutMs": openCost,
                    "initialVisibleWidth": initialWidth, "finalVisibleWidth": recorder.panelWidth,
                    "opened": recorder.panelPresented,
                    "firstShiftMs": recorder.firstShiftMs.map { $0 as Any } ?? "not observed",
                    "samples": recorder.samples
                ], name: "latency-\(mode)-\(attempt)")
                _ = try #require(recorder.firstShiftMs, "the real panel must expose growing width when Decor opens")
                #expect(recorder.panelPresented)
                #expect(recorder.panelWidth >= 300)
                print("ARC LATENCY mode=\(mode) attempt=\(attempt) openCallAndFirstLayoutMs=\(openCost) firstShiftMs=\(String(describing: recorder.firstShiftMs)) samples=\(recorder.samples.count)")
                await settle(window)
                if recorder.panelPresented {
                    try pressDecor(in: window)
                    await settle(window)
                }
                #expect(!recorder.panelPresented, "both native and Arc inspectors must close before the next opening")
                #expect(recorder.panelWidth <= 0.5)
            }
            EditorWindowController.closeAllForTesting()
        }
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

    /// The real card, at two widths: the colour control is one button while
    /// the card is narrower than the widest line, the row of swatches once it
    /// is wide enough. Found by what each draws: the button's tooltip is the
    /// word "Color", a swatch's is its own colour's name.
    @Test func arcColorControlFollowsTheCardWidth() async throws {
        guard #available(macOS 26, *) else { return }
        let restore = configureArc(true)
        defer { restore() }
        let document = EditorDocument(
            baseImage: TestImages.make(width: 1600, height: 800),
            sourceURL: URL(fileURLWithPath: "/tmp/editor-arc-color-control.png"))
        let annotation = Annotation(kind: .rect, start: CGPoint(x: 20, y: 20),
                                    end: CGPoint(x: 60, y: 60), color: .red, lineWidth: 4)
        document.beginChange()
        document.annotations.append(annotation)
        document.commitChange()
        document.selectedID = annotation.id

        weak var editorWindow: NSWindow?
        let context = EditorWindowContext(isKeyWindow: { editorWindow?.isKeyWindow == true },
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
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        await settle(window)
        try pressDecor(in: window)
        await settle(window)
        let split = try #require(frameSplit(in: window))

        let button = LocaleManager.shared.string("Color")
        let names = Set(EditorView.annotationColorNames.map { LocaleManager.shared.string($0) })
        func colorControl() -> (button: Int, swatches: Int) {
            let tips = views(in: split.detailHosting.view)
                .filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap(\.toolTip)
            return (tips.filter { $0 == button }.count, tips.filter { names.contains($0) }.count)
        }

        let card = split.detailHosting.view.bounds.width - ArcFrameLayout.frameGap
        #expect(card == 804)
        let narrow = colorControl()
        #expect(narrow.button == 1 && narrow.swatches == 0, "a 804pt card must fold the colours into one button")

        window.setContentSize(NSSize(width: 1280, height: 720))
        await settle(window)
        #expect(split.detailHosting.view.bounds.width - ArcFrameLayout.frameGap == 944)
        let wide = colorControl()
        #expect(wide.button == 0 && wide.swatches == names.count, "a 944pt card must keep the row of swatches")
    }

    /// What the Arc window sets so its frame runs up to the toolbar unbroken —
    /// no system rule under the titlebar, no scroller across the panel — and
    /// what every other window keeps. The window's own setting does not reach
    /// split items, so each is read too.
    @Test func arcWindowDropsTheTitlebarRuleAndThePanelScroller() async throws {
        guard #available(macOS 26, *) else { return }
        let restore = configureArc(true)
        let url = try writePNG("editor-arc-rule.png", width: 1600, height: 800)
        defer {
            EditorWindowController.closeAllForTesting()
            restore()
            try? FileManager.default.removeItem(at: url)
        }
        func outerScroller(_ root: NSView) -> NSScrollView? {
            views(in: root).compactMap { $0 as? NSScrollView }
                .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        }

        let arc = try await openWindow(url)
        try pressDecor(in: arc)
        await settle(arc)
        let split = try #require(frameSplit(in: arc))
        #expect(arc.titlebarSeparatorStyle == .none)
        #expect(split.splitViewItems.count == 2)
        for item in split.splitViewItems { #expect(item.titlebarSeparatorStyle == .none) }
        let arcScroller = try #require(outerScroller(split.panelHosting.view))
        #expect(!arcScroller.hasVerticalScroller)
        EditorWindowController.closeAllForTesting()

        AppSettings.store.set(false, forKey: AppSettings.Keys.editorArcFrame)
        let legacy = try await openWindow(url)
        try pressDecor(in: legacy)
        await settle(legacy)
        #expect(legacy.titlebarSeparatorStyle == .automatic)
        let content = try #require(legacy.contentView)
        let legacySplit = try #require(views(in: content).compactMap { $0 as? NSSplitView }
            .compactMap { $0.delegate as? NSSplitViewController }.first)
        for item in legacySplit.splitViewItems { #expect(item.titlebarSeparatorStyle == .automatic) }
        let legacyScroller = try #require(outerScroller(content))
        #expect(legacyScroller.hasVerticalScroller)
    }

    /// An Arc editor on a document of our own, so a test can select an
    /// annotation and read the row it draws. Not the controller's window:
    /// the controller keeps its document to itself.
    private func hostedArcWindow(document: EditorDocument) -> NSWindow {
        weak var editorWindow: NSWindow?
        let context = EditorWindowContext(isKeyWindow: { editorWindow?.isKeyWindow == true },
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
        return window
    }

    /// The row's two axes, measured on the real panel and the real second
    /// line: the first header's frame is centred on the line's axis (20pt
    /// below the top, where the colour button is centred too), the tile under
    /// it starts on the line's divider (40pt), and the compact colour button
    /// and its dot have their approved size.
    @Test func arcPanelHeaderAndColourButtonShareTheSecondLinesAxis() async throws {
        guard #available(macOS 26, *) else { return }
        let restore = configureArc(true)
        defer { restore() }
        let document = EditorDocument(
            baseImage: TestImages.make(width: 1600, height: 800),
            sourceURL: URL(fileURLWithPath: "/tmp/editor-arc-axis.png"))
        let annotation = Annotation(kind: .rect, start: CGPoint(x: 20, y: 20),
                                    end: CGPoint(x: 60, y: 60), color: .red, lineWidth: 4)
        document.beginChange()
        document.annotations.append(annotation)
        document.commitChange()
        document.selectedID = annotation.id
        let window = hostedArcWindow(document: document)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        await settle(window)
        try pressDecor(in: window)
        await settle(window)
        let split = try #require(frameSplit(in: window))
        let panel = split.panelHosting.view
        let detail = split.detailHosting.view
        func fromTop(_ rect: NSRect, in view: NSView) -> NSRect {
            NSRect(x: rect.minX, y: view.isFlipped ? rect.minY : view.bounds.maxY - rect.maxY,
                   width: rect.width, height: rect.height)
        }

        // The first header: the system's focus frame around the section title.
        let headers = views(in: panel).filter {
            !$0.isHiddenOrHasHiddenAncestor && String(describing: type(of: $0)) == "_FocusRingView"
        }.map { fromTop($0.convert($0.bounds, to: panel), in: panel) }
            .filter { $0.width > panel.bounds.width / 2 && $0.height >= 20 && $0.height <= 40 }
        let header = try #require(headers.min { $0.minY < $1.minY })
        #expect(abs(header.minY - 6) <= 0.5, "the panel's top inset is not 6pt")
        #expect(abs(header.height - 28) <= 0.5)

        // The second line's axis: the compact colour button, found by its tooltip.
        let tip = LocaleManager.shared.string("Color")
        let carrier = try #require(views(in: detail).first { $0.toolTip == tip },
                                   "a 804pt card must show the colour button")
        let button = fromTop(carrier.convert(carrier.bounds, to: detail), in: detail)
        #expect(abs(button.width - 52) <= 0.5 && abs(button.height - 24) <= 0.5,
                "the colour button is \(button.width) × \(button.height), not 52 × 24")
        #expect(abs(button.midY - 20) <= 0.5, "the second line's axis moved")
        #expect(abs(header.midY - button.midY) <= 1, "the first header is off the second line's axis")

        // The tile under the header: the first row of the panel's own picture
        // that is not transparent, below the header's frame.
        let panelPicture = try #require(panel.bitmapImageRepForCachingDisplay(in: panel.bounds))
        panel.cacheDisplay(in: panel.bounds, to: panelPicture)
        let panelScale = CGFloat(panelPicture.pixelsWide) / panel.bounds.width
        let column = Int(panel.bounds.midX * panelScale)
        var tileTop: CGFloat?
        var y = header.maxY - 2
        while y < 80 {
            let alpha = panelPicture.colorAt(x: column, y: Int(y * panelScale))?.alphaComponent ?? 0
            if alpha > 0.02 { tileTop = y; break }
            y += 0.5
        }
        let top = try #require(tileTop, "no tile under the first header")
        #expect(abs(top - 40) <= 1, "the first tile starts at \(top)pt, not on the second line's divider (40)")

        // The dot: red pixels on the button's middle row.
        let picture = try #require(detail.bitmapImageRepForCachingDisplay(in: detail.bounds))
        detail.cacheDisplay(in: detail.bounds, to: picture)
        let scale = CGFloat(picture.pixelsWide) / detail.bounds.width
        let row = Int(button.midY * scale)
        var dot = 0
        for x in Int(button.minX * scale)..<Int(button.maxX * scale) {
            guard let c = picture.colorAt(x: x, y: row)?.usingColorSpace(.sRGB) else { continue }
            let chroma = max(c.redComponent, c.greenComponent, c.blueComponent)
                - min(c.redComponent, c.greenComponent, c.blueComponent)
            if chroma > 0.25 { dot += 1 }
        }
        #expect(abs(CGFloat(dot) / scale - 16) <= 1, "the dot is \(CGFloat(dot) / scale)pt wide, not 16")
    }

    /// The window's width floor on its own display: 1140, or the visible width
    /// where the screen is narrower — a CI runner's is 1024. The product's rule,
    /// asked of the window's screen, not a number that holds only on a big one.
    private func arcMinimumWidth(of window: NSWindow) -> CGFloat {
        ArcFrameLayout.minimumContentWidth(
            visibleScreenWidth: window.screen?.visibleFrame.width ?? ArcFrameLayout.minimumWidth)
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
            window.backgroundColor.setFill()
            NSRect(origin: .zero, size: opaque.size).fill()
            let image = NSImage(size: opaque.size)
            image.addRepresentation(bitmap)
            image.draw(in: NSRect(origin: .zero, size: opaque.size), from: .zero,
                       operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
        let data = try #require(opaque.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: ArcChromeEvidence.folder, withIntermediateDirectories: true)
        let url = ArcChromeEvidence.folder.appendingPathComponent("\(name).png")
        try data.write(to: url)
        print("PROBE \(url.path)")
    }
}
