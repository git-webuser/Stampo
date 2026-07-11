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
}
