import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Stampo

@MainActor
@Suite struct EditorRenderRevisionTests {
    private func makeDocument() -> EditorDocument {
        EditorDocument(
            baseImage: TestImages.make(width: 16, height: 12),
            sourceURL: URL(fileURLWithPath: "/tmp/render-revision.png")
        )
    }

    @Test func renderSnapshotCarriesRevisionOfItsInputs() {
        let document = makeDocument()
        let before = document.makeRenderSnapshot(format: "png")

        document.annotations = [Annotation(
            kind: .rect,
            start: CGPoint(x: 1, y: 1),
            end: CGPoint(x: 8, y: 8),
            color: .red,
            lineWidth: 2
        )]
        let after = document.makeRenderSnapshot(format: "png")

        #expect(after.revision > before.revision)
        #expect(before.annotations.isEmpty)
        #expect(after.annotations.count == 1)
    }

    @Test func renderSnapshotAndEncodedArtifactCarryPresentation() throws {
        let document = makeDocument()
        let presentation = Presentation(
            canvas: .preset(pixelSize: CGSize(width: 32, height: 24)),
            background: .solid(.white)
        )
        document.presentation = presentation

        let snapshot = document.makeRenderSnapshot(format: "png")
        #expect(snapshot.presentation == presentation)

        let artifact = try #require(AnnotationRenderer.renderEncoded(snapshot: snapshot))
        let source = try #require(CGImageSourceCreateWithData(artifact.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 32)
        #expect(image.height == 24)
    }

    @Test func artifactFromOldSnapshotCannotRepresentCurrentRevision() {
        let document = makeDocument()
        let snapshot = document.makeRenderSnapshot(format: "png")
        document.annotations.append(Annotation(
            kind: .oval,
            start: CGPoint(x: 2, y: 2),
            end: CGPoint(x: 10, y: 10),
            color: .blue,
            lineWidth: 2
        ))

        let artifact = AnnotationRenderer.renderEncoded(snapshot: snapshot)
        #expect(artifact?.revision == snapshot.revision)
        #expect(artifact?.revision != document.revision)
    }

    @Test func renderArtifactUsesTheRequestedFormatOnce() throws {
        let document = makeDocument()

        for format in EditorExportFormat.allCases {
            let snapshot = document.makeRenderSnapshot(format: format.rawValue)
            let artifact = try #require(AnnotationRenderer.renderEncoded(snapshot: snapshot))
            #expect(artifact.format == format.rawValue)

            let source = try #require(CGImageSourceCreateWithData(artifact.data as CFData, nil))
            let identifier = try #require(CGImageSourceGetType(source) as String?)
            let actualType = try #require(UTType(identifier))
            #expect(actualType.conforms(to: format.contentType))
        }
    }

    @Test func baseImageRevisionAdvancesAcrossRotateUndoAndRedo() {
        let document = makeDocument()
        let initial = document.imageRevision

        document.rotate(clockwise: true)
        let rotated = document.imageRevision
        #expect(rotated > initial)

        document.undo()
        let undone = document.imageRevision
        #expect(undone > rotated)

        document.redo()
        #expect(document.imageRevision > undone)
    }
}
