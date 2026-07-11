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

    @Test func blurAndTextHitAnywhereInside() {
        var blur = make(.blur, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 60, y: 40))
        blur.blurStyle = .gaussian
        #expect(blur.hitTest(CGPoint(x: 35, y: 25), tolerance: 4))
        #expect(!blur.hitTest(CGPoint(x: 100, y: 100), tolerance: 4))
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

    @Test func cornerHandleKeepsOppositeCornerFixed() {
        var a = make(.rect, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 50, y: 40))
        a.apply(handle: .topLeft, to: CGPoint(x: 0, y: 0))
        #expect(a.rect == CGRect(x: 0, y: 0, width: 50, height: 40))
        // The bottom-right corner never moved.
        a.apply(handle: .bottomRight, to: CGPoint(x: 60, y: 70))
        #expect(a.rect == CGRect(x: 0, y: 0, width: 60, height: 70))
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

    // MARK: degenerate

    @Test func degenerateDetection() {
        #expect(make(.arrow, start: .zero, end: CGPoint(x: 2, y: 2)).isDegenerate)
        #expect(!make(.arrow, start: .zero, end: CGPoint(x: 40, y: 0)).isDegenerate)
        #expect(make(.rect, start: .zero, end: CGPoint(x: 3, y: 100)).isDegenerate)
        var text = make(.text, start: .zero, end: .zero)
        text.text = "   "
        #expect(text.isDegenerate)
        text.text = "label"
        #expect(!text.isDegenerate)
    }
}
