import Foundation
import Testing
@testable import Stampo

@Suite struct AnnotationGeometryTests {

    private func make(_ kind: AnnotationKind,
                      start: CGPoint, end: CGPoint,
                      lineWidth: CGFloat = 4) -> Annotation {
        Annotation(kind: kind, start: start, end: end, color: .red, lineWidth: lineWidth)
    }

    // MARK: rect normalization

    @Test func rectNormalizesAnyDragDirection() {
        let a = make(.rect, start: CGPoint(x: 100, y: 80), end: CGPoint(x: 20, y: 30))
        #expect(a.rect == CGRect(x: 20, y: 30, width: 80, height: 50))
    }

    // MARK: distance to segment

    @Test func distanceToSegment() {
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 10, y: 0)
        #expect(Annotation.distance(from: CGPoint(x: 5, y: 3), toSegment: a, b) == 3)
        // Beyond the endpoint the distance is to the endpoint itself.
        #expect(Annotation.distance(from: CGPoint(x: 14, y: 3), toSegment: a, b) == 5)
        // Degenerate zero-length segment.
        #expect(Annotation.distance(from: CGPoint(x: 3, y: 4), toSegment: a, a) == 5)
    }

    // MARK: hit testing

    @Test func arrowHitsNearShaftOnly() {
        let a = make(.arrow, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0))
        #expect(a.hitTest(CGPoint(x: 50, y: 5), tolerance: 4))
        #expect(!a.hitTest(CGPoint(x: 50, y: 30), tolerance: 4))
    }

    @Test func lineHitsNearSegmentAndHasEndpointHandles() {
        let line = make(.line, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0))
        #expect(line.hitTest(CGPoint(x: 50, y: 5), tolerance: 4))
        #expect(!line.hitTest(CGPoint(x: 50, y: 30), tolerance: 4))
        #expect(line.handles.map(\.0) == [.start, .end])
    }

    @Test func rectHitsBorderNotInterior() {
        let a = make(.rect, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 110, y: 90))
        #expect(a.hitTest(CGPoint(x: 60, y: 11), tolerance: 4))   // top edge
        #expect(a.hitTest(CGPoint(x: 109, y: 50), tolerance: 4))  // right edge
        #expect(!a.hitTest(CGPoint(x: 60, y: 50), tolerance: 4))  // deep inside
        #expect(!a.hitTest(CGPoint(x: 200, y: 50), tolerance: 4)) // far outside
    }

    @Test func ovalHitsOutline() {
        let a = make(.oval, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100))
        #expect(a.hitTest(CGPoint(x: 50, y: 1), tolerance: 4))    // top of circle
        #expect(a.hitTest(CGPoint(x: 99, y: 50), tolerance: 4))   // right of circle
        #expect(!a.hitTest(CGPoint(x: 50, y: 50), tolerance: 4))  // center
    }

    @Test func filledShapesHitTheirInterior() {
        var rect = make(.rect, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 70))
        rect.fillOpacity = 0.2
        #expect(rect.hitTest(CGPoint(x: 50, y: 40), tolerance: 0))

        var oval = make(.oval, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 90))
        oval.fillOpacity = 0.2
        #expect(oval.hitTest(CGPoint(x: 50, y: 50), tolerance: 0))
    }

    @Test func blurAndTextHitAnywhereInside() {
        var blur = make(.blur, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 60, y: 40))
        blur.blurStyle = .gaussian
        #expect(blur.hitTest(CGPoint(x: 35, y: 25), tolerance: 4))
        #expect(!blur.hitTest(CGPoint(x: 100, y: 100), tolerance: 4))
    }

    @Test func stepUsesCircularBoundsAndIsMoveOnly() {
        var step = make(.step, start: CGPoint(x: 50, y: 40), end: CGPoint(x: 50, y: 40))
        step.stepDiameter = 40
        #expect(step.rect == CGRect(x: 30, y: 20, width: 40, height: 40))
        #expect(step.hitTest(CGPoint(x: 50, y: 40), tolerance: 0))
        #expect(!step.hitTest(CGPoint(x: 75, y: 40), tolerance: 0))
        #expect(step.handles.isEmpty)
        step.move(by: CGPoint(x: 10, y: -5))
        #expect(step.start == CGPoint(x: 60, y: 35))
    }

    @Test func freehandBoundsHitTestingSamplingAndMove() {
        var stroke = make(.freehand, start: .zero, end: .zero, lineWidth: 4)
        let addedFirstPoint = stroke.appendFreehandPoint(
            CGPoint(x: 10, y: 10),
            minimumDistance: 1
        )
        let ignoredNearbyPoint = stroke.appendFreehandPoint(
            CGPoint(x: 10.2, y: 10.2),
            minimumDistance: 1
        )
        let addedSecondPoint = stroke.appendFreehandPoint(
            CGPoint(x: 20, y: 20),
            minimumDistance: 1
        )

        #expect(addedFirstPoint)
        #expect(!ignoredNearbyPoint)
        #expect(addedSecondPoint)
        #expect(stroke.rect == CGRect(x: 8, y: 8, width: 14, height: 14))
        #expect(stroke.hitTest(CGPoint(x: 15, y: 16), tolerance: 1))
        #expect(!stroke.hitTest(CGPoint(x: 15, y: 30), tolerance: 1))
        #expect(stroke.handles.isEmpty)

        stroke.move(by: CGPoint(x: 5, y: -3))
        #expect(stroke.freehandPoints == [CGPoint(x: 15, y: 7), CGPoint(x: 25, y: 17)])
    }

    @Test func freehandEraserCutsAStrokeIntoFragments() {
        var stroke = make(.freehand, start: .zero, end: .zero, lineWidth: 4)
        stroke.freehandStyle = .marker
        for x in stride(from: CGFloat(0), through: 100, by: 10) {
            stroke.appendFreehandPoint(CGPoint(x: x, y: 50), minimumDistance: 0)
        }

        let result = stroke.erasingFreehand(
            from: CGPoint(x: 50, y: 30), to: CGPoint(x: 50, y: 70), radius: 6
        )
        #expect(result.changed)
        #expect(result.fragments.count == 2)
        #expect(result.fragments[0].id == stroke.id)
        #expect(result.fragments[1].id != stroke.id)
        #expect(result.fragments.allSatisfy { $0.freehandStyle == .marker })
        #expect(result.fragments.allSatisfy {
            !$0.hitTest(CGPoint(x: 50, y: 50), tolerance: 0)
        })
    }

    @Test func freehandEraserNoOpPreservesIdentityAndGeometry() {
        var stroke = make(.freehand, start: .zero, end: .zero)
        stroke.appendFreehandPoint(CGPoint(x: 5, y: 5), minimumDistance: 0)
        stroke.appendFreehandPoint(CGPoint(x: 20, y: 5), minimumDistance: 0)
        let result = stroke.erasingFreehand(
            from: CGPoint(x: 50, y: 50), to: CGPoint(x: 60, y: 60), radius: 4
        )
        #expect(!result.changed)
        #expect(result.fragments == [stroke])
    }

    // MARK: handles

    @Test func arrowHasEndpointHandles() {
        let a = make(.arrow, start: CGPoint(x: 5, y: 6), end: CGPoint(x: 50, y: 60))
        let kinds = a.handles.map(\.0)
        #expect(kinds == [.start, .end])
        #expect(a.handle(at: CGPoint(x: 6, y: 7), tolerance: 5) == .start)
        #expect(a.handle(at: CGPoint(x: 49, y: 59), tolerance: 5) == .end)
        #expect(a.handle(at: CGPoint(x: 25, y: 30), tolerance: 5) == nil)
    }

    @Test func rectHasFourCornerHandles() {
        let a = make(.rect, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 40, y: 20))
        #expect(a.handles.count == 4)
        #expect(a.handle(at: CGPoint(x: 40, y: 20), tolerance: 3) == .bottomRight)
        #expect(a.handle(at: CGPoint(x: 0, y: 20), tolerance: 3) == .bottomLeft)
    }

    @Test func textIsMoveOnly() {
        var a = make(.text, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 60, y: 20))
        a.text = "hi"
        #expect(a.handles.isEmpty)
    }

    @Test func moveShiftsBothPoints() {
        var a = make(.rect, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 30, y: 30))
        a.move(by: CGPoint(x: 5, y: -3))
        #expect(a.start == CGPoint(x: 15, y: 7))
        #expect(a.end == CGPoint(x: 35, y: 27))
    }

    @Test func duplicateGetsNewIdentityAndPreservesEveryProperty() {
        var source = make(.freehand, start: CGPoint(x: 10, y: 20),
                          end: CGPoint(x: 50, y: 70), lineWidth: 12)
        source.color = .blue
        source.text = "copy"
        source.fontSize = 42
        source.bold = true
        source.italic = true
        source.underline = true
        source.strikethrough = true
        source.textShadow = true
        source.textBackground = .dark
        source.blurStyle = .gaussian
        source.blurLevel = 5
        source.fillOpacity = 0.35
        source.arrowStyle = .bold
        source.arrowHeadPlacement = .both
        source.lineStyle = .dashed
        source.stepLabel = "7"
        source.stepDiameter = 64
        source.freehandStyle = .marker
        source.freehandPoints = [CGPoint(x: 10, y: 20), CGPoint(x: 25, y: 40)]

        let copy = source.duplicated(offset: CGPoint(x: 12, y: -4))
        #expect(copy.id != source.id)
        #expect(copy.kind == source.kind)
        #expect(copy.start == CGPoint(x: 22, y: 16))
        #expect(copy.end == CGPoint(x: 62, y: 66))
        #expect(copy.color == source.color)
        #expect(copy.lineWidth == source.lineWidth)
        #expect(copy.text == source.text && copy.fontSize == source.fontSize)
        #expect(copy.bold == source.bold && copy.italic == source.italic)
        #expect(copy.underline == source.underline)
        #expect(copy.strikethrough == source.strikethrough)
        #expect(copy.textShadow == source.textShadow)
        #expect(copy.textBackground == source.textBackground)
        #expect(copy.blurStyle == source.blurStyle && copy.blurLevel == source.blurLevel)
        #expect(copy.fillOpacity == source.fillOpacity)
        #expect(copy.arrowStyle == source.arrowStyle)
        #expect(copy.arrowHeadPlacement == source.arrowHeadPlacement)
        #expect(copy.lineStyle == source.lineStyle)
        #expect(copy.stepLabel == source.stepLabel && copy.stepDiameter == source.stepDiameter)
        #expect(copy.freehandStyle == source.freehandStyle)
        #expect(copy.freehandPoints == [CGPoint(x: 22, y: 16), CGPoint(x: 37, y: 36)])
    }

    @Test func cornerHandleKeepsOppositeCornerFixed() {
        var a = make(.rect, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 50, y: 40))
        a.apply(handle: .topLeft, to: CGPoint(x: 0, y: 0))
        #expect(a.rect == CGRect(x: 0, y: 0, width: 50, height: 40))
        // The bottom-right corner never moved.
        a.apply(handle: .bottomRight, to: CGPoint(x: 60, y: 70))
        #expect(a.rect == CGRect(x: 0, y: 0, width: 60, height: 70))
    }

    @Test func aspectLockPreservesSquareAcrossQuadrants() {
        #expect(Annotation.aspectLockedEnd(from: CGPoint(x: 10, y: 10),
                                           to: CGPoint(x: 30, y: 15)) == CGPoint(x: 30, y: 30))
        #expect(Annotation.aspectLockedEnd(from: CGPoint(x: 10, y: 10),
                                           to: CGPoint(x: 3, y: 40)) == CGPoint(x: -20, y: 40))
    }

    // MARK: arrowhead

    @Test func arrowheadBarbsAreSymmetricAndBehindTip() {
        let from = CGPoint(x: 0, y: 0), tip = CGPoint(x: 100, y: 0)
        let (b1, b2) = Annotation.arrowheadBarbs(from: from, tip: tip, lineWidth: 4)
        // Symmetric around the shaft axis (y = 0).
        #expect(abs(b1.y + b2.y) < 0.001)
        #expect(abs(b1.x - b2.x) < 0.001)
        // Behind the tip, in front of the tail.
        #expect(b1.x < 100 && b1.x > 0)
    }

    @Test func arrowheadScalesWithLineWidth() {
        let from = CGPoint(x: 0, y: 0), tip = CGPoint(x: 100, y: 0)
        let (thin, _) = Annotation.arrowheadBarbs(from: from, tip: tip, lineWidth: 1)
        let (thick, _) = Annotation.arrowheadBarbs(from: from, tip: tip, lineWidth: 10)
        // Thicker stroke -> longer head -> barb sits further from the tip.
        #expect((100 - thick.x) > (100 - thin.x))
    }

    @Test func arrowEndpointSnapsToNearest45DegreeRay() {
        let origin = CGPoint(x: 10, y: 10)
        let horizontal = Annotation.snappedArrowEnd(from: origin, to: CGPoint(x: 60, y: 8))
        #expect(abs(horizontal.y - 10) < 0.001)
        let diagonal = Annotation.snappedArrowEnd(from: origin, to: CGPoint(x: 45, y: 40))
        #expect(abs((diagonal.x - 10) - (diagonal.y - 10)) < 0.001)
    }

    // MARK: degenerate

    @Test func degenerateDetection() {
        #expect(make(.line, start: .zero, end: CGPoint(x: 2, y: 2)).isDegenerate)
        #expect(!make(.line, start: .zero, end: CGPoint(x: 40, y: 0)).isDegenerate)
        #expect(make(.arrow, start: .zero, end: CGPoint(x: 2, y: 2)).isDegenerate)
        #expect(!make(.arrow, start: .zero, end: CGPoint(x: 40, y: 0)).isDegenerate)
        #expect(make(.rect, start: .zero, end: CGPoint(x: 3, y: 100)).isDegenerate)
        var text = make(.text, start: .zero, end: .zero)
        text.text = "   "
        #expect(text.isDegenerate)
        text.text = "label"
        #expect(!text.isDegenerate)
        var freehand = make(.freehand, start: .zero, end: .zero)
        #expect(freehand.isDegenerate)
        freehand.appendFreehandPoint(.zero, minimumDistance: 0)
        #expect(!freehand.isDegenerate)
    }
}
