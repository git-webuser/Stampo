import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Stampo

@Suite struct EditorUndoTests {

    private func makeDocument() -> EditorDocument {
        EditorDocument(baseImage: TestImages.make(width: 8, height: 8),
                       sourceURL: URL(fileURLWithPath: "/tmp/test.png"))
    }

    private func annotation(_ x: CGFloat = 0) -> Annotation {
        Annotation(kind: .rect, start: CGPoint(x: x, y: 0),
                   end: CGPoint(x: x + 20, y: 20), color: .red, lineWidth: 4)
    }

    @Test func commitPushesOnlyRealChanges() {
        let doc = makeDocument()
        doc.beginChange()
        doc.commitChange()                    // nothing changed
        #expect(!doc.canUndo)

        doc.beginChange()
        doc.annotations.append(annotation())
        doc.commitChange()
        #expect(doc.canUndo)
        #expect(doc.undoStack.count == 1)
    }

    @Test func undoRedoRoundTrip() {
        let doc = makeDocument()
        doc.beginChange()
        doc.annotations.append(annotation())
        doc.commitChange()

        doc.undo()
        #expect(doc.annotations.isEmpty)
        #expect(doc.canRedo)

        doc.redo()
        #expect(doc.annotations.count == 1)
        #expect(!doc.canRedo)
    }

    @Test func newChangeClearsRedo() {
        let doc = makeDocument()
        doc.beginChange()
        doc.annotations.append(annotation())
        doc.commitChange()
        doc.undo()
        #expect(doc.canRedo)

        doc.beginChange()
        doc.annotations.append(annotation(50))
        doc.commitChange()
        #expect(!doc.canRedo)
    }

    @Test func discardRestoresSnapshotWithoutPush() {
        let doc = makeDocument()
        doc.beginChange()
        doc.annotations.append(annotation())
        doc.discardChange()
        #expect(doc.annotations.isEmpty)
        #expect(!doc.canUndo)
    }

    @Test func undoDropsStaleSelection() {
        let doc = makeDocument()
        let a = annotation()
        doc.beginChange()
        doc.annotations.append(a)
        doc.commitChange()
        doc.selectedID = a.id

        doc.undo()
        #expect(doc.selectedID == nil)
    }

    @Test func deleteSelectedIsUndoable() {
        let doc = makeDocument()
        let a = annotation()
        doc.beginChange()
        doc.annotations.append(a)
        doc.commitChange()

        doc.selectedID = a.id
        doc.deleteSelected()
        #expect(doc.annotations.isEmpty)

        doc.undo()
        #expect(doc.annotations.count == 1)
    }

    @Test func dirtyTrackingFollowsSaves() {
        let doc = makeDocument()
        #expect(!doc.isDirty)

        doc.beginChange()
        doc.annotations.append(annotation())
        doc.commitChange()
        #expect(doc.isDirty)

        doc.markSaved()
        #expect(!doc.isDirty)

        // Undoing past the save point makes it dirty again.
        doc.undo()
        #expect(doc.isDirty)
    }

    @Test func finishingTextEditMeasuresAndCommitsIt() {
        let doc = makeDocument()
        var text = annotation()
        text.kind = .text
        text.start = CGPoint(x: 4, y: 6)
        text.end = text.start
        text.text = "Текст"
        text.fontSize = 24

        doc.beginChange()
        doc.annotations.append(text)
        doc.selectedID = text.id
        doc.finishTextEditing(text.id)

        #expect(doc.annotations[0].end.x > text.start.x)
        #expect(doc.annotations[0].end.y > text.start.y)
        #expect(doc.canUndo)
    }

    @Test func finishingEmptyTextEditRemovesItWithoutHistory() {
        let doc = makeDocument()
        var text = annotation()
        text.kind = .text
        text.end = text.start

        doc.beginChange()
        doc.annotations.append(text)
        doc.selectedID = text.id
        doc.finishTextEditing(text.id)

        #expect(doc.annotations.isEmpty)
        #expect(doc.selectedID == nil)
        #expect(!doc.canUndo)
        #expect(!doc.isDirty)
    }

    @Test func keyboardNudgeIsUndoable() {
        let doc = makeDocument()
        let a = annotation()
        doc.beginChange()
        doc.annotations.append(a)
        doc.commitChange()
        doc.selectedID = a.id

        doc.nudgeSelected(by: CGPoint(x: 10, y: -1))
        #expect(doc.annotations[0].start == CGPoint(x: 10, y: -1))
        doc.undo()
        #expect(doc.annotations[0].start == .zero)
    }

    @Test func duplicateSelectedCascadesAndRoundTripsThroughHistory() {
        let doc = makeDocument()
        let source = annotation()
        doc.annotations = [source]
        doc.selectedID = source.id

        let firstID = doc.duplicateSelected()
        #expect(doc.annotations.count == 2)
        #expect(firstID != source.id)
        #expect(doc.selectedID == firstID)
        #expect(doc.annotations.last?.start == CGPoint(x: 40, y: 40))

        let secondID = doc.duplicateSelected()
        #expect(doc.annotations.count == 3)
        #expect(doc.selectedID == secondID)
        #expect(doc.annotations.last?.start == CGPoint(x: 80, y: 80))

        doc.undo()
        #expect(doc.annotations.count == 2)
        doc.redo()
        #expect(doc.annotations.count == 3)
        #expect(doc.annotations.last?.id == secondID)
    }

    @Test func everyAnnotationKindCanBeDuplicated() {
        let kinds: [AnnotationKind] = [
            .line, .arrow, .rect, .oval, .text, .freehand, .blur, .step
        ]
        for kind in kinds {
            let doc = makeDocument()
            var source = Annotation(kind: kind, start: CGPoint(x: 1, y: 2),
                                    end: CGPoint(x: 5, y: 6), color: .red, lineWidth: 4)
            if kind == .text { source.text = "Text" }
            doc.annotations = [source]
            doc.selectedID = source.id
            #expect(doc.duplicateSelected() != nil)
            #expect(doc.annotations.last?.kind == kind)
        }
    }

    @Test func editorToolShortcutsCoverEveryPickerTool() {
        let expected: [(UInt16, EditorTool, String)] = [
            (9, .select, "V"), (37, .line, "L"), (0, .arrow, "A"),
            (15, .rect, "R"), (31, .oval, "O"), (17, .text, "T"),
            (35, .drawing, "P"),
            (14, .eraser, "E"),
            (11, .blur, "B"), (1, .step, "S"), (46, .loupe, "M")
        ]

        #expect(expected.count == EditorTool.pickerCases.count)
        for (keyCode, tool, label) in expected {
            #expect(EditorTool.tool(forShortcutKeyCode: keyCode) == tool)
            #expect(tool.shortcut?.label == label)
        }
        #expect(EditorTool.tool(forShortcutKeyCode: 7) == nil)
        #expect(EditorTool.ocr.shortcut == nil)
        #expect(EditorTool.crop.shortcut == nil)
    }

    @Test func oneEraserGestureIsOneUndoStepAndIgnoresOtherKinds() {
        let doc = makeDocument()
        var pen = Annotation(kind: .freehand, start: .zero,
                             end: CGPoint(x: 100, y: 0), color: .red, lineWidth: 4)
        pen.freehandPoints = stride(from: CGFloat(0), through: 100, by: 10)
            .map { CGPoint(x: $0, y: 20) }
        var marker = pen.duplicated(offset: CGPoint(x: 0, y: 20))
        marker.freehandStyle = .marker
        let arrow = Annotation(kind: .arrow, start: CGPoint(x: 0, y: 30),
                               end: CGPoint(x: 100, y: 30), color: .blue, lineWidth: 4)
        let original = [pen, marker, arrow]
        doc.annotations = original

        doc.beginChange()
        #expect(doc.eraseFreehand(from: CGPoint(x: 50, y: 0),
                                  to: CGPoint(x: 50, y: 50), diameter: 12))
        doc.commitChange()
        #expect(doc.undoStack.count == 1)
        #expect(doc.annotations.filter { $0.kind == .freehand }.count == 4)
        #expect(doc.annotations.contains { $0 == arrow })

        doc.undo()
        #expect(doc.annotations == original)
        doc.redo()
        #expect(doc.annotations.filter { $0.kind == .freehand }.count == 4)
    }

    @Test func rotateTransformsEveryFreehandPoint() {
        let doc = makeDocument()
        var stroke = Annotation(kind: .freehand, start: CGPoint(x: 1, y: 2),
                                end: CGPoint(x: 6, y: 2), color: .red, lineWidth: 2)
        stroke.freehandPoints = [stroke.start, stroke.end]
        doc.annotations = [stroke]

        doc.rotate(clockwise: true)
        #expect(doc.annotations[0].freehandPoints == [
            CGPoint(x: 6, y: 1), CGPoint(x: 6, y: 6)
        ])
        doc.undo()
        #expect(doc.annotations == [stroke])
    }

    @Test func zoomScalesAndClampsPanInTheSameUpdate() {
        let baseDrawSize = CGSize(width: 500, height: 300)
        let viewport = CGSize(width: 600, height: 400)

        let scaled = EditorViewportGeometry.scaledPanOffset(
            CGSize(width: 160, height: -80), from: 2, to: 1.5
        )
        #expect(scaled == CGSize(width: 120, height: -60))

        let clamped = EditorViewportGeometry.clampedPanOffset(
            scaled, baseDrawSize: baseDrawSize, zoom: 1.5, viewport: viewport
        )
        #expect(clamped == CGSize(width: 75, height: -25))

        let fitted = EditorViewportGeometry.clampedPanOffset(
            CGSize(width: 75, height: -25),
            baseDrawSize: baseDrawSize, zoom: 1, viewport: viewport
        )
        #expect(fitted == .zero)
    }

    @Test func textStyleShortcutsUseExpectedExactModifiers() {
        let expected: [(TextStyleFlag, UInt16, NSEvent.ModifierFlags, String)] = [
            (.bold, 11, .command, "⌘B"),
            (.italic, 34, .command, "⌘I"),
            (.underline, 32, .command, "⌘U"),
            (.strikethrough, 7, [.command, .shift], "⇧⌘X"),
            (.shadow, 4, [.command, .shift], "⇧⌘H")
        ]

        for (flag, keyCode, modifiers, label) in expected {
            #expect(TextStyleFlag.shortcut(keyCode: keyCode, modifiers: modifiers) == flag)
            #expect(flag.shortcut.label == label)
        }
        #expect(TextStyleFlag.shortcut(keyCode: 4, modifiers: .command) == nil)
        #expect(TextStyleFlag.shortcut(keyCode: 1, modifiers: .command) == nil)
    }

    @Test func togglingSelectedTextStyleIsUndoableAndRefitsBounds() {
        let doc = makeDocument()
        var text = Annotation(kind: .text, start: CGPoint(x: 2, y: 3),
                              end: CGPoint(x: 4, y: 5), color: .red, lineWidth: 4)
        text.text = "Shortcut"
        text.fontSize = 24
        doc.annotations = [text]
        doc.selectedID = text.id

        let enabled = doc.toggleTextStyle(.bold)
        #expect(enabled == true)
        #expect(doc.selectedAnnotation?.bold == true)
        #expect((doc.selectedAnnotation?.end.x ?? 0) > text.end.x)
        #expect(doc.undoStack.count == 1)

        doc.undo()
        #expect(doc.selectedAnnotation?.bold == false)
        #expect(doc.selectedAnnotation?.end == text.end)
        doc.redo()
        #expect(doc.selectedAnnotation?.bold == true)
    }

    @Test func inlineTextStyleJoinsTheOpenEditUndoStep() {
        let doc = makeDocument()
        var text = Annotation(kind: .text, start: .zero, end: CGPoint(x: 20, y: 20),
                              color: .red, lineWidth: 4)
        text.text = "Before"
        doc.annotations = [text]
        doc.selectedID = text.id

        doc.beginChange()
        doc.updateSelected { $0.text = "After" }
        #expect(doc.toggleTextStyle(.italic, annotationID: text.id, undoable: false) == true)
        doc.finishTextEditing(text.id)
        #expect(doc.undoStack.count == 1)

        doc.undo()
        #expect(doc.selectedAnnotation?.text == "Before")
        #expect(doc.selectedAnnotation?.italic == false)
    }

    @Test func duplicateAndMoveCanShareOneUndoStep() {
        let doc = makeDocument()
        let source = annotation()
        doc.annotations = [source]
        doc.selectedID = source.id

        doc.beginChange()
        let copyID = doc.appendDuplicate(of: source.id)
        doc.updateSelected { $0.move(by: CGPoint(x: 30, y: 5)) }
        doc.commitChange()

        #expect(doc.annotations.count == 2)
        #expect(doc.selectedID == copyID)
        #expect(doc.annotations.last?.start == CGPoint(x: 30, y: 5))
        #expect(doc.undoStack.count == 1)
        doc.undo()
        #expect(doc.annotations == [source])
    }

    @Test func arrowHeadPlacementChangeIsUndoable() {
        let doc = makeDocument()
        var arrow = Annotation(kind: .arrow, start: .zero, end: CGPoint(x: 40, y: 0),
                               color: .red, lineWidth: 4)
        arrow.arrowHeadPlacement = .end
        doc.annotations = [arrow]
        doc.selectedID = arrow.id

        doc.beginChange()
        doc.updateSelected { $0.arrowHeadPlacement = .both }
        doc.commitChange()
        #expect(doc.selectedAnnotation?.arrowHeadPlacement == .both)
        doc.undo()
        #expect(doc.selectedAnnotation?.arrowHeadPlacement == .end)
    }

    @Test func hitTestPrefersNonBlurOverBlur() {
        let doc = makeDocument()
        var rect = Annotation(kind: .rect, start: .zero, end: CGPoint(x: 40, y: 40),
                              color: .red, lineWidth: 4)
        rect.fillOpacity = 0.2   // filled, so its interior hit-tests
        let blur = Annotation(kind: .blur, start: .zero, end: CGPoint(x: 40, y: 40),
                              color: .red, lineWidth: 0)
        // Blur sits last (topmost by array order) but must not win the hit.
        doc.annotations = [rect, blur]
        #expect(doc.annotation(at: CGPoint(x: 20, y: 20), tolerance: 2)?.kind == .rect)
    }

    @Test func rotateSwapsDimensionsAndMarksDirty() {
        let doc = EditorDocument(baseImage: TestImages.make(width: 8, height: 4),
                                 sourceURL: URL(fileURLWithPath: "/tmp/test.png"))
        #expect(doc.pixelSize == CGSize(width: 8, height: 4))
        #expect(!doc.isDirty)
        doc.rotate(clockwise: true)
        #expect(doc.pixelSize == CGSize(width: 4, height: 8))
        #expect(doc.isDirty)   // image changed even with no annotation edits
    }

    @Test func fourRotationsRestoreCoordinates() {
        let doc = EditorDocument(baseImage: TestImages.make(width: 8, height: 4),
                                 sourceURL: URL(fileURLWithPath: "/tmp/test.png"))
        var a = Annotation(kind: .arrow, start: CGPoint(x: 1, y: 2),
                           end: CGPoint(x: 6, y: 3), color: .red, lineWidth: 2)
        a.kind = .rect
        doc.annotations = [a]
        for _ in 0..<4 { doc.rotate(clockwise: true) }
        #expect(doc.pixelSize == CGSize(width: 8, height: 4))
        #expect(doc.annotations[0].start == CGPoint(x: 1, y: 2))
        #expect(doc.annotations[0].end == CGPoint(x: 6, y: 3))
    }

    @Test func rotateIsUndoable() {
        let doc = EditorDocument(baseImage: TestImages.make(width: 8, height: 4),
                                 sourceURL: URL(fileURLWithPath: "/tmp/test.png"))
        doc.rotate(clockwise: true)
        #expect(doc.pixelSize == CGSize(width: 4, height: 8))
        #expect(doc.canUndo)
        doc.undo()
        #expect(doc.pixelSize == CGSize(width: 8, height: 4))
    }

    @Test func cropShrinksImageAndOffsetsAnnotations() {
        let doc = EditorDocument(baseImage: TestImages.make(width: 20, height: 20),
                                 sourceURL: URL(fileURLWithPath: "/tmp/test.png"))
        doc.annotations = [Annotation(kind: .rect, start: CGPoint(x: 10, y: 10),
                                      end: CGPoint(x: 14, y: 14), color: .red, lineWidth: 2)]
        doc.crop(to: CGRect(x: 8, y: 8, width: 8, height: 8))
        #expect(doc.pixelSize == CGSize(width: 8, height: 8))
        #expect(doc.annotations.count == 1)
        #expect(doc.annotations[0].start == CGPoint(x: 2, y: 2))   // shifted by -origin
        #expect(doc.isDirty)
    }

    @Test func cropDropsAnnotationsOutsideRegion() {
        let doc = EditorDocument(baseImage: TestImages.make(width: 20, height: 20),
                                 sourceURL: URL(fileURLWithPath: "/tmp/test.png"))
        let inside = Annotation(kind: .rect, start: CGPoint(x: 2, y: 2),
                                end: CGPoint(x: 6, y: 6), color: .red, lineWidth: 2)
        let outside = Annotation(kind: .rect, start: CGPoint(x: 15, y: 15),
                                 end: CGPoint(x: 19, y: 19), color: .red, lineWidth: 2)
        doc.annotations = [inside, outside]
        doc.crop(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        #expect(doc.annotations.count == 1)
        #expect(doc.annotations[0].id == inside.id)
    }

    @Test func cropIsUndoableAndRestoresImageAndAnnotations() {
        let doc = EditorDocument(baseImage: TestImages.make(width: 20, height: 20),
                                 sourceURL: URL(fileURLWithPath: "/tmp/test.png"))
        doc.annotations = [Annotation(kind: .rect, start: CGPoint(x: 10, y: 10),
                                      end: CGPoint(x: 14, y: 14), color: .red, lineWidth: 2)]
        doc.crop(to: CGRect(x: 4, y: 4, width: 8, height: 8))
        #expect(doc.pixelSize == CGSize(width: 8, height: 8))

        doc.undo()
        #expect(doc.pixelSize == CGSize(width: 20, height: 20))
        #expect(doc.annotations[0].start == CGPoint(x: 10, y: 10))
    }

    @Test func fullImageCropIsANoOp() {
        let doc = EditorDocument(baseImage: TestImages.make(width: 12, height: 8),
                                 sourceURL: URL(fileURLWithPath: "/tmp/test.png"))
        doc.crop(to: CGRect(x: 0, y: 0, width: 12, height: 8))
        #expect(doc.pixelSize == CGSize(width: 12, height: 8))
        #expect(!doc.canUndo)
        #expect(!doc.isDirty)
    }

    @Test func rotatePointClockwiseThenCounterReturnsOriginal() {
        let size = CGSize(width: 8, height: 4)
        let p = CGPoint(x: 3, y: 1)
        let cw = EditorDocument.rotatePoint(p, in: size, clockwise: true)
        // After a CW turn the frame is 4×8; the inverse turn uses that size.
        let back = EditorDocument.rotatePoint(cw, in: CGSize(width: 4, height: 8), clockwise: false)
        #expect(back == p)
    }

    @Test func nextStepLabelFollowsHighestNumericMarker() {
        let doc = makeDocument()
        var first = annotation()
        first.kind = .step
        first.stepLabel = "1"
        var third = annotation(40)
        third.kind = .step
        third.stepLabel = "3"
        doc.annotations = [first, third]
        #expect(doc.nextStepLabel == "4")
    }

    @Test func nextStepLabelIgnoresNonNumericLabels() {
        let doc = makeDocument()
        var custom = annotation()
        custom.kind = .step
        custom.stepLabel = "1.1"       // custom labels don't advance the count
        var numbered = annotation(40)
        numbered.kind = .step
        numbered.stepLabel = "2"
        doc.annotations = [custom, numbered]
        #expect(doc.nextStepLabel == "3")
    }

    // MARK: Curved arrows

    @Test func bendGestureUndoRestoresStraightArrow() {
        let doc = makeDocument()
        var arrow = annotation()
        arrow.kind = .arrow
        doc.annotations = [arrow]

        doc.beginChange()                          // control-handle drag begins
        doc.annotations[0].curveControl = CGPoint(x: 10, y: 30)
        doc.commitChange()
        #expect(doc.annotations[0].curveControl == CGPoint(x: 10, y: 30))

        doc.undo()
        #expect(doc.annotations[0].curveControl == nil)
    }

    @Test func rotateRemapsCurveControl() {
        let doc = EditorDocument(baseImage: TestImages.make(width: 8, height: 4),
                                 sourceURL: URL(fileURLWithPath: "/tmp/test.png"))
        var arrow = Annotation(kind: .arrow, start: CGPoint(x: 1, y: 1),
                               end: CGPoint(x: 7, y: 3), color: .red, lineWidth: 2)
        arrow.curveControl = CGPoint(x: 4, y: 2)
        doc.annotations = [arrow]

        doc.rotate(clockwise: true)                // (x,y) → (H−y, x), H = 4
        #expect(doc.annotations[0].curveControl == CGPoint(x: 2, y: 4))

        doc.undo()
        #expect(doc.annotations[0].curveControl == CGPoint(x: 4, y: 2))
    }

    @Test func cropOffsetsCurveControl() {
        let doc = EditorDocument(baseImage: TestImages.make(width: 20, height: 20),
                                 sourceURL: URL(fileURLWithPath: "/tmp/test.png"))
        var arrow = Annotation(kind: .arrow, start: CGPoint(x: 8, y: 8),
                               end: CGPoint(x: 16, y: 16), color: .red, lineWidth: 2)
        arrow.curveControl = CGPoint(x: 12, y: 8)
        doc.annotations = [arrow]

        doc.crop(to: CGRect(x: 4, y: 4, width: 12, height: 12))
        #expect(doc.annotations[0].curveControl == CGPoint(x: 8, y: 4))
    }

    // MARK: Z-order

    @Test func bringForwardSwapsAdjacentAndUndoRestores() {
        let doc = makeDocument()
        let a = annotation(), b = annotation(30), c = annotation(60)
        doc.annotations = [a, b, c]
        doc.selectedID = b.id

        doc.bringSelectedForward()
        #expect(doc.annotations.map(\.id) == [a.id, c.id, b.id])
        #expect(doc.undoStack.count == 1)

        doc.undo()
        #expect(doc.annotations.map(\.id) == [a.id, b.id, c.id])
    }

    @Test func sendBackwardSwapsAdjacent() {
        let doc = makeDocument()
        let a = annotation(), b = annotation(30)
        doc.annotations = [a, b]
        doc.selectedID = b.id

        doc.sendSelectedBackward()
        #expect(doc.annotations.map(\.id) == [b.id, a.id])
        #expect(doc.undoStack.count == 1)
    }

    @Test func reorderAtBoundaryIsNoOp() {
        let doc = makeDocument()
        let a = annotation(), b = annotation(30)
        doc.annotations = [a, b]

        doc.selectedID = b.id
        doc.bringSelectedForward()          // already topmost
        #expect(!doc.canUndo)
        #expect(doc.annotations.map(\.id) == [a.id, b.id])

        doc.selectedID = a.id
        doc.sendSelectedBackward()          // already bottom
        #expect(!doc.canUndo)
        #expect(doc.annotations.map(\.id) == [a.id, b.id])
    }

    @Test func reorderSkipsOtherRenderGroup() {
        let doc = makeDocument()
        let a = annotation()
        var blur = annotation(30)
        blur.kind = .blur
        let b = annotation(60)
        doc.annotations = [a, blur, b]

        // Forward from a skips the blur (separate bottom render layer) and
        // swaps with b, the next annotation in the same visual group.
        doc.selectedID = a.id
        doc.bringSelectedForward()
        #expect(doc.annotations.map(\.id) == [b.id, blur.id, a.id])

        // A lone blur has no same-group neighbor: true no-op.
        doc.selectedID = blur.id
        doc.bringSelectedForward()
        #expect(doc.annotations.map(\.id) == [b.id, blur.id, a.id])
        #expect(doc.undoStack.count == 1)
    }

    @Test func toFrontAndToBackAreSingleUndoSteps() {
        let doc = makeDocument()
        let a = annotation(), b = annotation(30), c = annotation(60)
        doc.annotations = [a, b, c]

        doc.selectedID = a.id
        doc.bringSelectedToFront()
        #expect(doc.annotations.map(\.id) == [b.id, c.id, a.id])
        #expect(doc.undoStack.count == 1)

        doc.sendSelectedToBack()
        #expect(doc.annotations.map(\.id) == [a.id, b.id, c.id])
        #expect(doc.undoStack.count == 2)

        doc.sendSelectedToBack()            // already at the back: no-op
        #expect(doc.undoStack.count == 2)
    }
}
