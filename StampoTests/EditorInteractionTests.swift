import CoreGraphics
import Testing
@testable import Stampo

/// The four decisions a press makes before anything moves: which tool acts,
/// whether an object is picked up, whether the picture is, and whether the tool
/// hands itself back afterwards.
///
/// These lived as methods reading the view's own state, which is why the ⌘
/// borrow could ship completely inert while the suite stayed green — nothing
/// could ask it what it answered. Every case below would have failed then.
@MainActor
@Suite struct EditorInteractionTests {

    // MARK: Which tool acts

    @Test func commandBorrowsSelectFromAMakerTool() {
        #expect(EditorCanvasView.actingTool(.blur, commandHeld: true) == .select)
        #expect(EditorCanvasView.actingTool(.drawing, commandHeld: true) == .select)
        #expect(EditorCanvasView.actingTool(.text, commandHeld: true) == .select)
    }

    /// The regression that shipped: without the modifier nothing may change,
    /// or every tool quietly becomes Select.
    @Test func withoutCommandTheToolIsUntouched() {
        for tool in EditorTool.allCases {
            #expect(EditorCanvasView.actingTool(tool, commandHeld: false) == tool)
        }
    }

    /// Recognition and crop own their gestures outright — a borrow there would
    /// hand a press to Select while an overlay is mid-selection.
    @Test func recognitionAndCropAreNeverBorrowedFrom() {
        #expect(EditorCanvasView.actingTool(.scan, commandHeld: true) == .scan)
        #expect(EditorCanvasView.actingTool(.crop, commandHeld: true) == .crop)
    }

    // MARK: The tracked ⌘ flag

    /// The bug this pins: pressing the colour picker's ⌃⌥⌘C inside the editor
    /// hands the key window to the picker's overlay, so the release of the chord
    /// is never heard by the editor. A mirror that kept saying "down" borrowed
    /// Select from every tool afterwards, and no tool could make an annotation
    /// again — on a decorated page each press grabbed the picture instead.
    @Test func aModifierChangeSeenWhileAnotherWindowIsKeyReleasesTheBorrow() {
        #expect(!EditorCanvasView.trackedCommand(eventSaysDown: true,
                                                 editorIsKey: false))
        #expect(!EditorCanvasView.trackedCommand(eventSaysDown: false,
                                                 editorIsKey: false))
    }

    /// And the ordinary case still tracks the key: the mirror is what repaints
    /// the cursor on the press itself.
    @Test func theBorrowIsTrackedWhileTheEditorIsKey() {
        #expect(EditorCanvasView.trackedCommand(eventSaysDown: true,
                                                editorIsKey: true))
        #expect(!EditorCanvasView.trackedCommand(eventSaysDown: false,
                                                 editorIsKey: true))
    }

    // MARK: What the pointer picks up

    /// Touching existing ink *is* the eraser's gesture, so ink that caught its
    /// pointer could never be erased.
    @Test func everyToolPicksObjectsUpExceptTheEraser() {
        for tool in EditorTool.allCases {
            let expected = tool != .eraser && tool != .scan && tool != .crop
            #expect(EditorCanvasView.picksUpObjects(tool) == expected,
                    "\(tool) picks up: \(EditorCanvasView.picksUpObjects(tool))")
        }
    }

    // MARK: Whether the picture takes the press

    private let page = CGRect(x: 100, y: 100, width: 200, height: 200)

    @Test func thePictureIsReachedOnlyUnderSelect() {
        let inside = CGPoint(x: 200, y: 200)
        #expect(EditorCanvasView.imageTakesPress(.select, isDecorated: true,
                                                 imageRect: page, point: inside,
                                                 grab: 8))
        // It lies under the whole canvas: letting a maker tool catch it would
        // mean never drawing on the screenshot again.
        for tool in EditorTool.allCases where tool != .select {
            #expect(!EditorCanvasView.imageTakesPress(tool, isDecorated: true,
                                                      imageRect: page, point: inside,
                                                      grab: 8))
        }
    }

    /// Without a page around it there is nowhere to move the picture to, so the
    /// press belongs to whatever is drawn on it.
    @Test func anUndecoratedPictureNeverTakesThePress() {
        #expect(!EditorCanvasView.imageTakesPress(.select, isDecorated: false,
                                                  imageRect: page,
                                                  point: CGPoint(x: 200, y: 200),
                                                  grab: 8))
    }

    /// The grab widens the rect by half, so the edge is catchable from just
    /// outside it — and only just.
    @Test func theEdgeIsCatchableFromJustOutside() {
        let justOutside = CGPoint(x: page.minX - 3, y: 200)   // grab 8 → 4 of slack
        let wellOutside = CGPoint(x: page.minX - 20, y: 200)
        #expect(EditorCanvasView.imageTakesPress(.select, isDecorated: true,
                                                 imageRect: page, point: justOutside,
                                                 grab: 8))
        #expect(!EditorCanvasView.imageTakesPress(.select, isDecorated: true,
                                                  imageRect: page, point: wellOutside,
                                                  grab: 8))
    }

    @Test func adegeneratePictureTakesNothing() {
        #expect(!EditorCanvasView.imageTakesPress(.select, isDecorated: true,
                                                  imageRect: .zero,
                                                  point: .zero, grab: 8))
    }

    // MARK: Whether the tool hands itself back

    /// A shape and a label are single finished statements; the tool resetting
    /// is the end of the act.
    @Test func shapesAndLabelsHandTheToolBack() {
        for tool in [EditorTool.rect, .oval, .line, .arrow, .roundedRect,
                     .polygon, .star, .bubble, .blur, .loupe, .text] {
            #expect(EditorCanvasView.handsBackAfterMaking(tool), "\(tool)")
        }
    }

    /// Strokes, erasing and numbering are done in runs — resetting after each
    /// one fights the user rather than saving them a trip.
    @Test func theToolsUsedInRunsKeepTheirTool() {
        for tool in [EditorTool.drawing, .eraser, .step, .select, .scan, .crop] {
            #expect(!EditorCanvasView.handsBackAfterMaking(tool), "\(tool)")
        }
    }

    /// Every tool is classified by both rules. A new one added to the picker
    /// has to be given an answer here rather than inheriting a default.
    @Test func everyToolIsAccountedFor() {
        let handsBack: Set<EditorTool> = [.line, .arrow, .rect, .oval, .roundedRect,
                                          .polygon, .star, .bubble, .blur, .loupe, .text]
        let keepsTool: Set<EditorTool> = [.select, .drawing, .eraser, .step, .scan, .crop]
        #expect(handsBack.union(keepsTool).count == EditorTool.allCases.count)
        #expect(handsBack.isDisjoint(with: keepsTool))
        for tool in EditorTool.allCases {
            #expect(EditorCanvasView.handsBackAfterMaking(tool) == handsBack.contains(tool),
                    "\(tool) is unclassified")
        }
    }
}
