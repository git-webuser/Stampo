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

    @Test func rectHitsInteriorEvenUnfilled() {
        // 0% fill still reads as the shape's body (Fitts): the interior
        // selects and drags without sniping the outline.
        let a = make(.rect, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 110, y: 90))
        #expect(a.hitTest(CGPoint(x: 60, y: 11), tolerance: 4))   // top edge
        #expect(a.hitTest(CGPoint(x: 60, y: 50), tolerance: 4))   // deep inside
        #expect(!a.hitTest(CGPoint(x: 200, y: 50), tolerance: 4)) // far outside
    }

    @Test func ovalHitsEllipseInteriorNotCorners() {
        let a = make(.oval, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100))
        #expect(a.hitTest(CGPoint(x: 50, y: 1), tolerance: 4))    // top of circle
        #expect(a.hitTest(CGPoint(x: 50, y: 50), tolerance: 4))   // center
        #expect(!a.hitTest(CGPoint(x: 3, y: 3), tolerance: 4))    // bounding-box corner
    }

    @Test func filledShapesHitTheirInterior() {
        var rect = make(.rect, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 70))
        rect.fillOpacity = 0.2
        #expect(rect.hitTest(CGPoint(x: 50, y: 40), tolerance: 0))

        var oval = make(.oval, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 90))
        oval.fillOpacity = 0.2
        #expect(oval.hitTest(CGPoint(x: 50, y: 50), tolerance: 0))
    }

    // MARK: collapse edge cases (minimum size)

    @Test func loupeBodiesNeverCollapse() {
        // In-place loupe: compressing a corner all the way onto the anchor
        // stops at the minimum size instead of vanishing.
        var inPlace = make(.loupe, start: CGPoint(x: 10, y: 10),
                           end: CGPoint(x: 90, y: 90))
        inPlace.apply(handle: .topLeft, to: CGPoint(x: 90, y: 90))
        #expect(inPlace.rect.size == CGSize(width: Annotation.minimumShapeSize,
                                            height: Annotation.minimumShapeSize))

        // Callout magnifier: the collapsing drag clamps (no mirroring for a
        // loupe), and the coupled source marker keeps a nonzero size too.
        var callout = make(.loupe, start: CGPoint(x: 100, y: 100),
                           end: CGPoint(x: 180, y: 180))
        callout.loupeSource = CGPoint(x: 40, y: 40)
        callout.loupeSourceSize = CGSize(width: 40, height: 40)
        let handle = callout.apply(handle: .topLeft, to: CGPoint(x: 500, y: 500))
        #expect(handle == .topLeft)   // no mirrored handle for a loupe
        #expect(callout.rect.size == CGSize(width: Annotation.minimumShapeSize,
                                            height: Annotation.minimumShapeSize))
        #expect((callout.loupeSourceSize?.width ?? 0) >= Annotation.minimumShapeSize)

        // Source marker: same guarantee from the other body's corners, with
        // the magnifier scaled in step but floored at the minimum.
        var c2 = make(.loupe, start: CGPoint(x: 100, y: 100),
                      end: CGPoint(x: 180, y: 180))
        c2.loupeSource = CGPoint(x: 40, y: 40)
        c2.loupeSourceSize = CGSize(width: 40, height: 40)
        c2.apply(handle: .sourceTopLeft, to: CGPoint(x: 60, y: 60))
        #expect(c2.loupeSourceSize == CGSize(width: Annotation.minimumShapeSize,
                                             height: Annotation.minimumShapeSize))
        #expect(c2.rect.width >= Annotation.minimumShapeSize)
        #expect(c2.rect.height >= Annotation.minimumShapeSize)
    }

    @Test func pathShapesStayValidAtMinimumSize() {
        for kind in [AnnotationKind.roundedRect, .polygon, .star, .bubble] {
            var a = make(kind, start: CGPoint(x: 12, y: 12),
                         end: CGPoint(x: 12 + Annotation.minimumShapeSize,
                                      y: 12 + Annotation.minimumShapeSize))
            a.polygonSides = ShapeCounts.polygonSides.lowerBound
            a.starPoints = ShapeCounts.starPoints.upperBound
            let outline = a.pathShapeOutline
            #expect(outline != nil && !(outline?.isEmpty ?? true))
            #expect(a.hitTest(CGPoint(x: 16, y: 16), tolerance: 4))
        }
    }

    // MARK: path shapes (rounded rect, polygon, star, bubble)

    @Test func triangularPolygonHitsPathInteriorNotBoundingBox() {
        var triangle = make(.polygon, start: CGPoint(x: 0, y: 0),
                            end: CGPoint(x: 100, y: 100))
        triangle.polygonSides = 3
        #expect(triangle.hitTest(CGPoint(x: 50, y: 1), tolerance: 4))    // apex
        #expect(triangle.hitTest(CGPoint(x: 50, y: 99), tolerance: 4))   // base
        #expect(triangle.hitTest(CGPoint(x: 50, y: 60), tolerance: 4))   // inside
        // Inside the bounding rect but outside the triangle: still a miss.
        #expect(!triangle.hitTest(CGPoint(x: 3, y: 5), tolerance: 4))
    }

    @Test func polygonAndStarVerticesFollowTheirCounts() {
        let square = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(Annotation.polygonVertices(sides: 6, in: square).count == 6)
        // First vertex sits at the top center.
        let top = Annotation.polygonVertices(sides: 5, in: square)[0]
        #expect(abs(top.x - 50) < 0.001 && abs(top.y) < 0.001)

        let star = Annotation.starVertices(points: 5, in: square)
        #expect(star.count == 10)   // outer points alternating with inner
        #expect(abs(star[0].x - 50) < 0.001 && abs(star[0].y) < 0.001)
    }

    @Test func polygonVerticesFillTheirBoundingRect() {
        // Fit-to-rect: no gap between flat sides and the bounds — a triangle's
        // base sits exactly on the bottom edge, corners at the rect corners.
        let square = CGRect(x: 0, y: 0, width: 100, height: 100)
        let triangle = Annotation.polygonVertices(sides: 3, in: square)
        let xs = triangle.map(\.x), ys = triangle.map(\.y)
        #expect(abs(xs.min()!) < 0.001 && abs(xs.max()! - 100) < 0.001)
        #expect(abs(ys.min()!) < 0.001 && abs(ys.max()! - 100) < 0.001)

        for count in ShapeCounts.starPoints {
            let ys = Annotation.starVertices(points: count, in: square).map(\.y)
            #expect(abs(ys.min()!) < 0.001 && abs(ys.max()! - 100) < 0.001)
        }
    }

    @Test func upwardCreationDragFlipsPolygonApexDownward() {
        // Drawing upward points the apex down — the funnel case. Orientation
        // is stored, set from the drag while creating.
        let flipped = Annotation.polygonVertices(
            sides: 3, in: CGRect(x: 0, y: 0, width: 100, height: 100),
            flippedVertically: true)
        #expect(abs(flipped[0].x - 50) < 0.001 && abs(flipped[0].y - 100) < 0.001)

        var funnel = make(.polygon, start: CGPoint(x: 0, y: 100),
                          end: CGPoint(x: 100, y: 0))
        funnel.polygonSides = 3
        funnel.updateCreationOrientation()
        #expect(funnel.flippedVertically)
        #expect(funnel.hitTest(CGPoint(x: 50, y: 99), tolerance: 4))   // apex at bottom
        #expect(!funnel.hitTest(CGPoint(x: 3, y: 95), tolerance: 4))   // outside old apex corner
    }

    @Test func resizeDeadZoneHoldsOrientationDecisiveCrossingFlipsIt() {
        var funnel = make(.polygon, start: CGPoint(x: 0, y: 100),
                          end: CGPoint(x: 100, y: 0))
        funnel.polygonSides = 3
        funnel.updateCreationOrientation()
        #expect(funnel.flippedVertically)

        // Ordinary resize: same handle back, orientation untouched.
        var handle = funnel.apply(handle: .bottomRight, to: CGPoint(x: 120, y: 120))
        #expect(handle == .bottomRight && funnel.flippedVertically)
        #expect(funnel.rect == CGRect(x: 0, y: 0, width: 120, height: 120))

        // Within ±minimumShapeSize of the anchor: the shape sits at the
        // minimum size on its original side — jitter can't flip it.
        handle = funnel.apply(handle: .bottomRight, to: CGPoint(x: 120, y: -4))
        #expect(handle == .bottomRight && funnel.flippedVertically)
        #expect(funnel.rect == CGRect(x: 0, y: 0, width: 120,
                                      height: Annotation.minimumShapeSize))

        // A decisive push through the opposite edge mirrors the shape: the
        // apex flips and the drag continues with the mirrored handle.
        handle = funnel.apply(handle: .bottomRight, to: CGPoint(x: 120, y: -40))
        #expect(handle == .topRight)
        #expect(!funnel.flippedVertically)
        #expect(funnel.rect == CGRect(x: 0, y: -40, width: 120, height: 40))

        // The continued drag with the mirrored handle keeps the same fixed
        // anchor and doesn't re-flip.
        handle = funnel.apply(handle: handle, to: CGPoint(x: 120, y: -60))
        #expect(handle == .topRight && !funnel.flippedVertically)
        #expect(funnel.rect == CGRect(x: 0, y: -60, width: 120, height: 60))
    }

    @Test func bubbleTailFollowsItsSideAndKeepsCornerHandles() {
        var bubble = make(.bubble, start: CGPoint(x: 0, y: 0),
                          end: CGPoint(x: 120, y: 80))
        bubble.bubbleTail = .left
        // The tail tip reaches the rect's bottom corner on the chosen side.
        #expect(bubble.hitTest(CGPoint(x: 1, y: 79), tolerance: 4))
        bubble.bubbleTail = .right
        #expect(bubble.hitTest(CGPoint(x: 119, y: 79), tolerance: 4))
        #expect(!bubble.hitTest(CGPoint(x: 1, y: 79), tolerance: 4))

        #expect(bubble.handles.map(\.0) ==
                [.topLeft, .topRight, .bottomLeft, .bottomRight])
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

    @Test func arrowHasEndpointAndCurveControlHandles() {
        let a = make(.arrow, start: CGPoint(x: 5, y: 6), end: CGPoint(x: 50, y: 60))
        let kinds = a.handles.map(\.0)
        #expect(kinds == [.start, .end, .control])
        #expect(a.handle(at: CGPoint(x: 6, y: 7), tolerance: 5) == .start)
        #expect(a.handle(at: CGPoint(x: 49, y: 59), tolerance: 5) == .end)
        // The bend control of a straight arrow sits at the midpoint.
        #expect(a.handle(at: CGPoint(x: 27, y: 33), tolerance: 5) == .control)
        #expect(a.handle(at: CGPoint(x: 15, y: 45), tolerance: 5) == nil)
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
        source.arrowStyle = .dashed
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

    // MARK: curved arrow

    /// Curve fixture: start (0,0), end (100,0), control (50,50) — the
    /// quadratic's apex is at (50,25).
    private func curvedArrow() -> Annotation {
        var a = make(.arrow, start: .zero, end: CGPoint(x: 100, y: 0))
        a.curveControl = CGPoint(x: 50, y: 50)
        return a
    }

    @Test func curvedArrowHitsCurveNotChord() {
        let a = curvedArrow()
        #expect(a.hitTest(CGPoint(x: 50, y: 22), tolerance: 4))   // near apex
        #expect(!a.hitTest(CGPoint(x: 50, y: 2), tolerance: 4))   // on the chord
    }

    @Test func curvedArrowRectIncludesBulge() {
        let a = curvedArrow()
        #expect(a.rect.maxY >= 20)
        #expect(a.rect.minX <= 0 && a.rect.maxX >= 100)
    }

    @Test func arrowHandlesIncludeControlAtMidpointWhenStraight() {
        let straight = make(.arrow, start: .zero, end: CGPoint(x: 100, y: 0))
        #expect(straight.handles.map(\.0) == [.start, .end, .control])
        #expect(straight.handles.last?.1 == CGPoint(x: 50, y: 0))

        let curved = curvedArrow()
        #expect(curved.handles.last?.1 == CGPoint(x: 50, y: 50))
    }

    @Test func applyControlHandleBendsArrowOnly() {
        var arrow = make(.arrow, start: .zero, end: CGPoint(x: 100, y: 0))
        arrow.apply(handle: .control, to: CGPoint(x: 50, y: 40))
        #expect(arrow.curveControl == CGPoint(x: 50, y: 40))

        var line = make(.line, start: .zero, end: CGPoint(x: 100, y: 0))
        line.apply(handle: .control, to: CGPoint(x: 50, y: 40))
        #expect(line.curveControl == nil)
    }

    @Test func moveOffsetsCurveControl() {
        var a = curvedArrow()
        a.move(by: CGPoint(x: 10, y: -5))
        #expect(a.curveControl == CGPoint(x: 60, y: 45))
    }

    @Test func duplicatedRetainsCurveControl() {
        let copy = curvedArrow().duplicated(offset: CGPoint(x: 10, y: 10))
        #expect(copy.curveControl == CGPoint(x: 60, y: 60))
    }

    @Test func arrowheadAnchorUsesControlUnlessDegenerate() {
        let a = curvedArrow()
        #expect(a.arrowheadAnchor(towardTip: a.end, opposite: a.start)
                == CGPoint(x: 50, y: 50))

        var degenerate = a
        degenerate.curveControl = CGPoint(x: 100, y: 0.5) // on top of the tip
        #expect(degenerate.arrowheadAnchor(towardTip: degenerate.end,
                                           opposite: degenerate.start) == degenerate.start)

        let straight = make(.arrow, start: .zero, end: CGPoint(x: 100, y: 0))
        #expect(straight.arrowheadAnchor(towardTip: straight.end,
                                         opposite: straight.start) == straight.start)
    }

    @Test func quadraticPointsSpanEndpoints() {
        let points = Annotation.quadraticPoints(from: .zero,
                                                control: CGPoint(x: 50, y: 50),
                                                to: CGPoint(x: 100, y: 0))
        #expect(points.first == .zero)
        #expect(points.last == CGPoint(x: 100, y: 0))
        // Apex sample: t = 0.5 → (50, 25).
        #expect(points.contains { abs($0.x - 50) < 0.001 && abs($0.y - 25) < 0.001 })
    }

    @Test func bendControlAlignsToStraightWithinBandOrWithShift() {
        let start = CGPoint.zero, end = CGPoint(x: 100, y: 0)
        // A clear bend keeps the drag point as the control.
        #expect(Annotation.bentControl(forDrag: CGPoint(x: 50, y: 40),
                                       start: start, end: end,
                                       snapDistance: 9, forceStraight: false)
                == CGPoint(x: 50, y: 40))
        // Within the alignment band of the chord → snaps straight (nil).
        #expect(Annotation.bentControl(forDrag: CGPoint(x: 50, y: 6),
                                       start: start, end: end,
                                       snapDistance: 9, forceStraight: false) == nil)
        // Just outside the band still bends.
        #expect(Annotation.bentControl(forDrag: CGPoint(x: 50, y: 12),
                                       start: start, end: end,
                                       snapDistance: 9, forceStraight: false) != nil)
        // Shift forces straight regardless of deviation.
        #expect(Annotation.bentControl(forDrag: CGPoint(x: 50, y: 40),
                                       start: start, end: end,
                                       snapDistance: 9, forceStraight: true) == nil)
    }

    @Test func arrowEndpointSnapsToNearest45DegreeRay() {
        let origin = CGPoint(x: 10, y: 10)
        let horizontal = Annotation.snappedArrowEnd(from: origin, to: CGPoint(x: 60, y: 8))
        #expect(abs(horizontal.y - 10) < 0.001)
        let diagonal = Annotation.snappedArrowEnd(from: origin, to: CGPoint(x: 45, y: 40))
        #expect(abs((diagonal.x - 10) - (diagonal.y - 10)) < 0.001)
    }

    // MARK: loupe

    @Test func loupeHitsFullDisk() {
        let a = make(.loupe, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 60, y: 60))
        #expect(a.hitTest(CGPoint(x: 40, y: 40), tolerance: 4))   // center
        #expect(a.hitTest(CGPoint(x: 58, y: 40), tolerance: 4))   // near the ring
        #expect(!a.hitTest(CGPoint(x: 62, y: 62), tolerance: 4))  // outside (corner)
        #expect(!a.hitTest(CGPoint(x: 80, y: 40), tolerance: 4))  // far outside
    }

    @Test func loupeHasFourCornerHandles() {
        let a = make(.loupe, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 40, y: 40))
        #expect(a.handles.count == 4)
        #expect(a.handle(at: CGPoint(x: 40, y: 40), tolerance: 3) == .bottomRight)
    }

    @Test func loupeCornerResizeLocksAspectOnlyWithShift() {
        var a = make(.loupe, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 40, y: 40))
        a.apply(handle: .bottomRight, to: CGPoint(x: 80, y: 50))
        #expect(a.rect.width == 80 && a.rect.height == 50)
        // Shift (aspectLocked) turns the oval into a circle.
        a.apply(handle: .bottomRight, to: CGPoint(x: 80, y: 50), aspectLocked: true)
        #expect(a.rect.width == a.rect.height)
    }

    @Test func ovalLoupeHitsEllipseNotCorners() {
        var a = make(.loupe, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 80, y: 40))
        a.loupeShape = .oval
        #expect(a.hitTest(CGPoint(x: 40, y: 20), tolerance: 4))   // center
        #expect(!a.hitTest(CGPoint(x: 76, y: 38), tolerance: 2))  // corner outside ellipse
    }

    @Test func roundedRectLoupeResizesFreelyAndHitsCorners() {
        var a = make(.loupe, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 40, y: 40))
        a.loupeShape = .roundedRect
        a.apply(handle: .bottomRight, to: CGPoint(x: 80, y: 50))
        #expect(a.rect.width == 80 && a.rect.height == 50)
        #expect(a.hitTest(CGPoint(x: 78, y: 48), tolerance: 2))   // corner is inside
        #expect(!a.hitTest(CGPoint(x: 90, y: 25), tolerance: 2))  // outside
    }

    /// A callout with an independently-sized marker frame.
    private func callout(display: CGRect, markerCenter: CGPoint,
                         markerSize: CGSize, scale: CGFloat = 2) -> Annotation {
        var a = make(.loupe, start: display.origin,
                     end: CGPoint(x: display.maxX, y: display.maxY))
        a.loupeScale = scale
        a.loupeSource = markerCenter
        a.loupeSourceSize = markerSize
        return a
    }

    @Test func calloutLoupeBodiesHitAndMoveIndependently() {
        var a = callout(display: CGRect(x: 100, y: 100, width: 40, height: 40),
                        markerCenter: CGPoint(x: 30, y: 30),
                        markerSize: CGSize(width: 20, height: 20))
        // The marker frame is its stored center and size — independent of scale.
        #expect(a.loupeSourceRect == CGRect(x: 20, y: 20, width: 20, height: 20))
        // Both bodies are hittable and route to their own part.
        #expect(a.hitTest(CGPoint(x: 30, y: 30), tolerance: 2))
        #expect(a.loupePart(at: CGPoint(x: 120, y: 120), tolerance: 2) == .display)
        #expect(a.loupePart(at: CGPoint(x: 30, y: 30), tolerance: 2) == .source)
        // Part drags leave the other body in place…
        a.moveLoupePart(.source, by: CGPoint(x: 5, y: 0))
        #expect(a.loupeSource == CGPoint(x: 35, y: 30))
        #expect(a.start == CGPoint(x: 100, y: 100))
        a.moveLoupePart(.display, by: CGPoint(x: -10, y: 0))
        #expect(a.start == CGPoint(x: 90, y: 100))
        #expect(a.loupeSource == CGPoint(x: 35, y: 30))
        // …while a whole-annotation move carries both.
        a.move(by: CGPoint(x: 10, y: 10))
        #expect(a.start == CGPoint(x: 100, y: 110))
        #expect(a.loupeSource == CGPoint(x: 45, y: 40))
    }

    @Test func calloutAddsSourceHandlesInPlaceLoupeDoesNot() {
        var a = make(.loupe, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 140, y: 140))
        // In-place loupe: only the four display corners.
        #expect(a.handles.count == 4)
        a.loupeSource = CGPoint(x: 30, y: 30)
        a.loupeSourceSize = CGSize(width: 20, height: 20)   // marker (20,20,20,20)
        let kinds = a.handles.map(\.0)
        #expect(a.handles.count == 8)           // display + source corners
        #expect(kinds.contains(.sourceBottomRight))
        // The marker's bottom-right corner sits at its stored rect edge.
        #expect(a.handle(at: CGPoint(x: 40, y: 40), tolerance: 3) == .sourceBottomRight)
        // And a display corner still resolves to its display handle.
        #expect(a.handle(at: CGPoint(x: 140, y: 140), tolerance: 3) == .bottomRight)
    }

    @Test func resizingEitherFrameScalesBothKeepingRatio() {
        // Marker 20×20, magnifier 40×40 → size ratio 2.
        var a = callout(display: CGRect(x: 100, y: 100, width: 40, height: 40),
                        markerCenter: CGPoint(x: 30, y: 30),
                        markerSize: CGSize(width: 20, height: 20))
        let markerCenter = a.loupeSource!
        // Drag the magnifier's bottom-right from 140→160 (×1.5 each axis).
        a.apply(handle: .bottomRight, to: CGPoint(x: 160, y: 160))
        #expect(a.rect.width == 60 && a.rect.height == 60)
        // Marker scales by the same factor about its own center (stays put).
        #expect(a.loupeSourceSize == CGSize(width: 30, height: 30))
        #expect(a.loupeSource == markerCenter)
    }

    @Test func resizingMarkerScalesMagnifierAboutItsCenter() {
        var a = callout(display: CGRect(x: 100, y: 100, width: 40, height: 40),
                        markerCenter: CGPoint(x: 30, y: 30),
                        markerSize: CGSize(width: 20, height: 20))
        let displayCenter = CGPoint(x: a.rect.midX, y: a.rect.midY)
        // Marker (20,20,20,20): drag top-left 20→10, anchoring corner (40,40).
        a.apply(handle: .sourceTopLeft, to: CGPoint(x: 10, y: 10))
        #expect(a.loupeSourceRect == CGRect(x: 10, y: 10, width: 30, height: 30))
        // Magnifier scales ×1.5 about its own center (stays put).
        #expect(a.rect.width == 60 && a.rect.height == 60)
        #expect(abs(a.rect.midX - displayCenter.x) < 0.001)
        #expect(abs(a.rect.midY - displayCenter.y) < 0.001)
    }

    @Test func changingMagnificationLeavesBothFramesInPlace() {
        var a = callout(display: CGRect(x: 100, y: 100, width: 40, height: 40),
                        markerCenter: CGPoint(x: 30, y: 30),
                        markerSize: CGSize(width: 20, height: 20))
        let marker = a.loupeSourceRect!
        let display = a.rect
        // Magnification is content zoom only — neither frame moves or resizes.
        a.loupeScale = 3.5
        #expect(a.loupeSourceRect == marker)
        #expect(a.rect == display)
    }

    @Test func calloutDisplayPlacementSizesAndClearsSource() {
        // The user draws the marker; the magnifier is source × scale beside it.
        let source = CGRect(x: 400, y: 300, width: 40, height: 40)
        let display = EditorCanvasView.calloutDisplayPlacement(
            source: source, scale: 2, lineWidth: 4,
            imageSize: CGSize(width: 1000, height: 800))
        #expect(display.width == 80 && display.height == 80)   // source × scale
        #expect(!display.intersects(source))                   // never overlaps
        // Stays on-image.
        #expect(display.minX >= 0 && display.minY >= 0)
        #expect(display.maxX <= 1000 && display.maxY <= 800)
    }

    @Test func calloutConnectorSpansEdgesAndHidesWhenOverlapping() {
        // Display: circle r20 centered (80,40); marker: r10 centered (20,40).
        var a = callout(display: CGRect(x: 60, y: 20, width: 40, height: 40),
                        markerCenter: CGPoint(x: 20, y: 40),
                        markerSize: CGSize(width: 20, height: 20))
        let points = a.loupeConnectorPoints()
        #expect(abs((points?.0.x ?? 0) - 30) < 0.001)   // marker's right edge
        #expect(abs((points?.0.y ?? 0) - 40) < 0.001)
        #expect(abs((points?.1.x ?? 0) - 60) < 0.001)   // display's left edge
        #expect(abs((points?.1.y ?? 0) - 40) < 0.001)
        // Overlapping bodies hide the connector.
        a.loupeSource = CGPoint(x: 75, y: 40)
        #expect(a.loupeConnectorPoints() == nil)
    }

    @Test func loupeDegenerateUnderFourPixels() {
        #expect(make(.loupe, start: .zero, end: CGPoint(x: 3, y: 3)).isDegenerate)
        #expect(!make(.loupe, start: .zero, end: CGPoint(x: 20, y: 20)).isDegenerate)
    }

    // MARK: arrow binding (resolver + ray-to-outline)

    /// Close-enough comparison for the flattened-outline resolver, whose
    /// path-shape crossings carry subdivision error.
    private func approx(_ a: CGPoint, _ b: CGPoint, tol: CGFloat = 0.5) -> Bool {
        abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol
    }

    @Test func unboundEndpointsResolveToRawPoints() {
        let target = make(.rect, start: CGPoint(x: 100, y: 100),
                          end: CGPoint(x: 200, y: 200))
        let arrow = make(.arrow, start: CGPoint(x: 0, y: 150),
                         end: CGPoint(x: 300, y: 150))
        #expect(arrow.resolvedStart(in: [target, arrow]) == CGPoint(x: 0, y: 150))
        #expect(arrow.resolvedEnd(in: [target, arrow]) == CGPoint(x: 300, y: 150))
    }

    @Test func dynamicBindingLandsOnRectEdgeAlongRay() {
        // Target rect centered (150,150), 100×100. Arrow comes from the left,
        // so the bound tip meets the rect's left-edge midpoint.
        let target = make(.rect, start: CGPoint(x: 100, y: 100),
                          end: CGPoint(x: 200, y: 200))
        var arrow = make(.arrow, start: CGPoint(x: 0, y: 150),
                         end: CGPoint(x: 999, y: 999))
        arrow.endBinding = EndpointBinding(targetID: target.id, anchor: .dynamic,
                                           fallback: .zero)
        #expect(approx(arrow.resolvedEnd(in: [target, arrow]),
                       CGPoint(x: 100, y: 150)))
        // The unbound start still reports its raw point.
        #expect(arrow.resolvedStart(in: [target, arrow]) == CGPoint(x: 0, y: 150))
    }

    @Test func dynamicBindingLandsOnEllipseNotBoundingBox() {
        // Wide oval centered (200,150), half-axes 100×50. Approach from
        // straight above → the top of the ellipse, not the bbox corner.
        let oval = make(.oval, start: CGPoint(x: 100, y: 100),
                        end: CGPoint(x: 300, y: 200))
        var arrow = make(.arrow, start: CGPoint(x: 200, y: 0),
                         end: CGPoint(x: 0, y: 0))
        arrow.endBinding = EndpointBinding(targetID: oval.id, anchor: .dynamic,
                                           fallback: .zero)
        #expect(approx(arrow.resolvedEnd(in: [oval, arrow]),
                       CGPoint(x: 200, y: 100)))
    }

    @Test func ovalAndRectOutlineDifferOnTheDiagonal() {
        // Same bounding rect: on a 45° ray the box reaches its corner while
        // the ellipse stops short — proof the resolver honors the outline.
        let r = make(.rect, start: .zero, end: CGPoint(x: 100, y: 100))
        let o = make(.oval, start: .zero, end: CGPoint(x: 100, y: 100))
        let toward = CGPoint(x: 200, y: 200)
        #expect(approx(r.outlinePoint(toward: toward), CGPoint(x: 100, y: 100)))
        let ovalHit = o.outlinePoint(toward: toward)
        #expect(approx(ovalHit, CGPoint(x: 85.36, y: 85.36)))
    }

    @Test func dynamicBindingLandsOnTriangleOutlineNotBoundingBox() {
        // Triangle in (0,0)…(100,100): apex (50,0), base corners (100,100)/(0,100).
        var triangle = make(.polygon, start: .zero, end: CGPoint(x: 100, y: 100))
        triangle.polygonSides = 3
        // From directly below: the base edge at (50,100).
        var fromBelow = make(.arrow, start: CGPoint(x: 50, y: 200), end: .zero)
        fromBelow.endBinding = EndpointBinding(targetID: triangle.id,
                                               anchor: .dynamic, fallback: .zero)
        #expect(approx(fromBelow.resolvedEnd(in: [triangle, fromBelow]),
                       CGPoint(x: 50, y: 100)))
        // From the right at mid-height: the right edge at x=75 (bbox would say 100).
        var fromRight = make(.arrow, start: CGPoint(x: 200, y: 50), end: .zero)
        fromRight.endBinding = EndpointBinding(targetID: triangle.id,
                                               anchor: .dynamic, fallback: .zero)
        #expect(approx(fromRight.resolvedEnd(in: [triangle, fromRight]),
                       CGPoint(x: 75, y: 50)))
    }

    @Test func bindingFallsBackWhenTargetIsGone() {
        var arrow = make(.arrow, start: CGPoint(x: 0, y: 0),
                         end: CGPoint(x: 50, y: 50))
        arrow.endBinding = EndpointBinding(targetID: UUID(), anchor: .dynamic,
                                           fallback: CGPoint(x: 7, y: 7))
        #expect(arrow.resolvedEnd(in: [arrow]) == CGPoint(x: 7, y: 7))
    }

    @Test func bothEndsDynamicAimShapeToShapeWithoutRecursion() {
        // Two rects 300 apart; each end binds to one. Each endpoint resolves
        // to the near edge facing the *other target's center*.
        let a = make(.rect, start: CGPoint(x: 100, y: 100),
                     end: CGPoint(x: 200, y: 200))   // center (150,150)
        let b = make(.rect, start: CGPoint(x: 400, y: 100),
                     end: CGPoint(x: 500, y: 200))   // center (450,150)
        var arrow = make(.arrow, start: CGPoint(x: 999, y: 999),
                         end: CGPoint(x: 999, y: 999))
        arrow.startBinding = EndpointBinding(targetID: a.id, anchor: .dynamic,
                                             fallback: .zero)
        arrow.endBinding = EndpointBinding(targetID: b.id, anchor: .dynamic,
                                           fallback: .zero)
        let list = [a, b, arrow]
        #expect(approx(arrow.resolvedStart(in: list), CGPoint(x: 200, y: 150)))
        #expect(approx(arrow.resolvedEnd(in: list), CGPoint(x: 400, y: 150)))
    }

    @Test func boundArrowHitAndHandlesUseResolvedEndpoints() {
        // Arrow from the left with its tip bound to a rect centered (150,150).
        // Its raw end is off at (300,150), but interaction must happen where
        // it's drawn: tip resolved to the left edge (100,150).
        let rect = make(.rect, start: CGPoint(x: 100, y: 100),
                        end: CGPoint(x: 200, y: 200))
        var arrow = make(.arrow, start: CGPoint(x: 0, y: 150),
                         end: CGPoint(x: 300, y: 150))
        arrow.endBinding = EndpointBinding(targetID: rect.id, anchor: .dynamic,
                                           fallback: .zero)
        let list = [rect, arrow]
        // Handle grab lands on the resolved tip, not the raw end.
        #expect(arrow.handle(at: CGPoint(x: 100, y: 150), tolerance: 6, in: list) == .end)
        #expect(arrow.handle(at: CGPoint(x: 300, y: 150), tolerance: 6, in: list) == nil)
        // Hit-testing follows the drawn shaft (0…100), not the stale raw shaft.
        #expect(arrow.hitTest(CGPoint(x: 50, y: 150), tolerance: 4, in: list))
        #expect(!arrow.hitTest(CGPoint(x: 200, y: 150), tolerance: 4, in: list))
        // With no bindings the resolved variants match the plain ones.
        let free = make(.arrow, start: .zero, end: CGPoint(x: 100, y: 0))
        #expect(free.handle(at: CGPoint(x: 100, y: 0), tolerance: 5, in: [free]) == .end)
    }

    /// True when some anchor sits within `tol` of `p`.
    private func hasAnchor(_ anchors: [ReferenceAnchor], at p: CGPoint,
                           visible: Bool? = nil, tol: CGFloat = 0.5) -> Bool {
        anchors.contains {
            abs($0.point.x - p.x) <= tol && abs($0.point.y - p.y) <= tol
                && (visible == nil || $0.isVisible == visible)
        }
    }

    @Test func ovalExposesFourVisibleAnchorsWithFreeCenter() {
        // Wide oval centered (200,150), half-axes 100×50.
        let oval = make(.oval, start: CGPoint(x: 100, y: 100),
                        end: CGPoint(x: 300, y: 200))
        let anchors = oval.referenceAnchors()
        #expect(anchors.count == 4 && anchors.allSatisfy(\.isVisible))
        #expect(hasAnchor(anchors, at: CGPoint(x: 200, y: 100)))   // top
        #expect(hasAnchor(anchors, at: CGPoint(x: 200, y: 200)))   // bottom
        #expect(hasAnchor(anchors, at: CGPoint(x: 100, y: 150)))   // left
        #expect(hasAnchor(anchors, at: CGPoint(x: 300, y: 150)))   // right
        // A drop toward an edge snaps to it…
        #expect(oval.nearestBindingAnchor(to: CGPoint(x: 200, y: 105))?.point
                == CGPoint(x: 200, y: 100))
        // …while a drop in the interior stays free (nil).
        #expect(oval.nearestBindingAnchor(to: CGPoint(x: 200, y: 150)) == nil)
        // Non-bindable kinds expose no anchors.
        #expect(make(.arrow, start: .zero, end: CGPoint(x: 10, y: 10))
            .referenceAnchors().isEmpty)
    }

    @Test func rectAnchorsAreVisibleEdgeMidsAndHiddenCorners() {
        let rect = make(.rect, start: .zero, end: CGPoint(x: 100, y: 60))
        let anchors = rect.referenceAnchors()
        #expect(anchors.filter(\.isVisible).count == 4)
        #expect(anchors.filter { !$0.isVisible }.count == 4)
        // Edge midpoints are the visible anchors.
        #expect(hasAnchor(anchors, at: CGPoint(x: 50, y: 0), visible: true))
        #expect(hasAnchor(anchors, at: CGPoint(x: 0, y: 30), visible: true))
        // Corners are hidden vertex anchors, still snappable.
        #expect(hasAnchor(anchors, at: CGPoint(x: 0, y: 0), visible: false))
        #expect(hasAnchor(anchors, at: CGPoint(x: 100, y: 60), visible: false))
        // A drop into a corner snaps to that (hidden) vertex.
        #expect(rect.nearestBindingAnchor(to: CGPoint(x: 6, y: 6))?.point == .zero)
    }

    @Test func polygonAnchorsRecomputePerSideCount() {
        // Triangle apex-up in (0,0)…(100,100): 3 hidden vertices (apex + base
        // corners) and 3 visible edge midpoints, all on the real outline.
        var triangle = make(.polygon, start: .zero, end: CGPoint(x: 100, y: 100))
        triangle.polygonSides = 3
        let anchors = triangle.referenceAnchors()
        #expect(anchors.filter { !$0.isVisible }.count == 3)   // vertices
        #expect(anchors.filter(\.isVisible).count == 3)        // edge mids
        #expect(hasAnchor(anchors, at: CGPoint(x: 50, y: 0), visible: false))    // apex
        #expect(hasAnchor(anchors, at: CGPoint(x: 50, y: 100), visible: true))   // base mid
        // Six-sided polygon recomputes to 6 + 6.
        triangle.polygonSides = 6
        #expect(triangle.referenceAnchors().count == 12)
    }

    @Test func fixedAnchorPlacesOnNormalizedBoundingRect() {
        let target = make(.rect, start: CGPoint(x: 100, y: 100),
                          end: CGPoint(x: 200, y: 300))   // 100×200
        var arrow = make(.arrow, start: .zero, end: CGPoint(x: 50, y: 50))
        arrow.endBinding = EndpointBinding(
            targetID: target.id,
            anchor: .fixed(unit: CGPoint(x: 0.5, y: 0)), fallback: .zero)
        #expect(arrow.resolvedEnd(in: [target, arrow]) == CGPoint(x: 150, y: 100))
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
