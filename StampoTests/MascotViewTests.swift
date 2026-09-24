import AppKit
import Testing
@testable import Stampo

/// What the menu bar actually shows, read back from the pixels.
///
/// Both of these were found by eye and would have been found by nothing else:
/// the paths were right, the layers were right, and the drawing was wrong.
@MainActor @Suite struct MascotViewTests {

    private let zoom = 8

    private func hare() -> MascotStatusView {
        let view = MascotStatusView(frame: NSRect(x: 0, y: 0, width: 22, height: 18))
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    private func render(_ state: MascotState) -> NSBitmapImageRep? {
        let view = hare()
        view.setState(state)
        return render(view)
    }

    private func render(_ view: MascotStatusView) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 22 * zoom, pixelsHigh: 18 * zoom,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep),
              let layer = view.layer else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(zoom), y: CGFloat(zoom))
        layer.render(in: context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func isInked(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
        guard let colour = rep.colorAt(x: x, y: y) else { return false }
        return colour.alphaComponent > 0.4 && colour.brightnessComponent > 0.5
    }

    /// Ink in the band the eyes live in, wherever they look: artwork x 2…10,
    /// y 8.3…11.7. The body's walls and the notch are outside it.
    private func eyeInk(_ rep: NSBitmapImageRep) -> Int {
        let toView = MascotStatusView.artworkToViewForTesting
        let a = CGPoint(x: 2, y: 8.3).applying(toView), b = CGPoint(x: 10, y: 11.7).applying(toView)
        var inked = 0
        for x in Int(min(a.x, b.x) * CGFloat(zoom))..<Int(max(a.x, b.x) * CGFloat(zoom)) {
            for viewY in Int(min(a.y, b.y) * CGFloat(zoom))..<Int(max(a.y, b.y) * CGFloat(zoom))
            where isInked(rep, x, 18 * zoom - 1 - viewY) {
                inked += 1
            }
        }
        return inked
    }

    /// The left eye's outline: how far across the view it spans, and where it
    /// starts — which is on the glint's side of the eye, the drawing being
    /// mirrored for the other gaze.
    private func leftEye(of view: MascotStatusView) throws -> (span: ClosedRange<CGFloat>, first: CGFloat) {
        var points: [CGPoint] = []
        try #require(view.eyePathsForTesting.0)
            .applyWithBlock { points.append($0.pointee.points[0]) }
        let xs = points.map(\.x)
        let low = try #require(xs.min()), high = try #require(xs.max())
        return (low...high, try #require(xs.first))
    }

    /// Where the glint's side starts, as a fraction of the eye's width.
    private func glint(of view: MascotStatusView) throws -> CGFloat {
        let eye = try leftEye(of: view)
        return (eye.first - eye.span.lowerBound) / (eye.span.upperBound - eye.span.lowerBound)
    }

    /// Nothing runs down the middle of the hare's face.
    ///
    /// The outline has a sharp notch between the ears, and a shape layer joins
    /// its lines with a miter unless told otherwise: the two nearly parallel
    /// strokes meeting there grew a spike ten line-widths long, straight down
    /// the face and past the eyes. The body it replaced was a squircle, so
    /// nothing had ever asked the question.
    ///
    /// Read from the drawing rather than from pixel counts: the band between
    /// where the notch ends and where the eyes begin, which is clean in the
    /// artwork and is where the spike ran. The notch itself is a narrow V and
    /// fills the middle column for its whole depth, so its length says
    /// nothing.
    @Test func theNotchBetweenTheEarsIsNotASpike() throws {
        let rep = try #require(render(.sleeping))
        let toView = MascotStatusView.artworkToViewForTesting

        /// An image row for a place on the hare, in the artwork's own units.
        func row(at artworkY: CGFloat) -> Int {
            let viewY = CGPoint(x: 0, y: artworkY).applying(toView).y
            return Int((18 - viewY) * CGFloat(zoom))
        }
        // The notch bottoms out at 6.18 in the drawing, and the stroke it is
        // drawn with reaches half its width further — call it 7.4 to be clear
        // of the round join. The eyes begin at 9.
        let from = row(at: 7.4), to = row(at: 8.9)
        let middle = 11 * zoom
        for y in from...to {
            for x in (middle - 1)...(middle + 1) {
                #expect(!isInked(rep, x, y),
                        "ink below the notch: it is drawing a spike again")
            }
        }
    }

    /// The carve in the eye is a highlight, not a pupil: it stays away from
    /// what the hare is looking at, the way a light does not move when an eye
    /// does. Looking one way the eye is the mirror of looking the other.
    ///
    /// Read from the path rather than from the pixels: the eye travels with
    /// the gaze, and every window drawn around it at fixed coordinates catches
    /// either the body's wall or the notch between the ears, both of which
    /// outweigh a two-point eye.
    @Test func theGlintSitsAwayFromTheGaze() throws {
        func eye(_ state: MascotState) throws -> (span: ClosedRange<CGFloat>, first: CGFloat) {
            let view = hare()
            view.setState(state)
            return try leftEye(of: view)
        }

        let left = try eye(.colorPicking(.leftCenter))
        let right = try eye(.colorPicking(.rightCenter))

        // The same eye, the same width, in two places.
        let width = left.span.upperBound - left.span.lowerBound
        #expect(abs((right.span.upperBound - right.span.lowerBound) - width) < 0.01)
        #expect(right.span.lowerBound > left.span.lowerBound, "the eye did not follow the gaze")

        // And drawn as each other's mirror: what is a fraction `f` across one
        // is `1 - f` across the other.
        let acrossLeft = (left.first - left.span.lowerBound) / width
        let acrossRight = (right.first - right.span.lowerBound) / width
        #expect(abs(acrossLeft + acrossRight - 1) < 0.02,
                "the eye is drawn the same way whichever way the hare looks")
    }

    /// Every state draws something, which is the least a mascot can do.
    @Test func everyStateDrawsAHare() throws {
        for state in [MascotState.sleeping, .awake, .waiting, .countdown,
                      .colorPicking(.leftUp), .celebrating] {
            let rep = try #require(render(state))
            var inked = 0
            for y in 0..<(18 * zoom) where inked == 0 {
                for x in 0..<(22 * zoom) where isInked(rep, x, y) { inked += 1 }
            }
            #expect(inked > 0, "\(state) drew nothing at all")
        }
    }

    /// A blink, a pop and a squeeze all scale the eye, and they have to do it
    /// about the eye's own middle.
    ///
    /// The eye layers had no size and sat at the view's origin, and a layer
    /// scales about its position — so every one of them pivoted on the
    /// bottom-left corner. At each blink the eyes dived three points to the
    /// bottom edge and came back; woken, they flew in from the corner; put to
    /// sleep, they fell to the floor. The drawing was right; only where it was
    /// pinned was wrong.
    @Test func anEyeShutsAboutItsOwnMiddle() throws {
        for state in [MascotState.awake, .colorPicking(.rightUp), .sleeping] {
            let view = hare()
            view.setState(state)
            let host = try #require(view.layer)
            for eye in view.eyeLayersForTesting {
                let drawn = try #require(eye.path).boundingBoxOfPath
                let open = eye.convert(drawn, to: host)
                // Measured where the eyes are, not at the corner they fell to.
                #expect(open.midY > 2, "\(state): the eye is not in its row to begin with")
                for squeeze in [CATransform3DMakeScale(1, 0.05, 1),    // a blink, shut
                                CATransform3DMakeScale(0.3, 0.3, 1)] { // a pop, early on
                    eye.transform = squeeze
                    let shut = eye.convert(drawn, to: host)
                    #expect(abs(shut.midY - open.midY) < 0.3,
                            "\(state): the eye moved \(shut.midY - open.midY) pt as it shut")
                    #expect(abs(shut.midX - open.midX) < 0.3,
                            "\(state): the eye moved \(shut.midX - open.midX) pt sideways as it shut")
                }
                eye.transform = CATransform3DIdentity
            }
        }
    }

    /// Sleep cut short leaves the eyes open, not gone.
    ///
    /// Squeezing the eyes shut takes them to zero height at once and puts the
    /// arcs up 130 ms later. A state arriving in between cancelled the arcs
    /// and found the eyes still counted as open, so it left them alone — at
    /// zero height, and the hare had no eyes until it next fell asleep. The
    /// colour picker hit exactly this: its first cursor reports land while
    /// the panel's hiding is still putting the hare to sleep.
    @Test func sleepCutShortLeavesTheEyesOpen() async throws {
        let control = try #require(render(.awake))
        #expect(eyeInk(control) > 100, "an awake hare's eyes are not where this looks")

        for next in [MascotState.awake, .colorPicking(.rightCenter)] {
            let view = hare()
            view.setState(.awake)
            view.setState(.sleeping)
            try await Task.sleep(for: .milliseconds(40))
            view.setState(next)
            try await Task.sleep(for: .milliseconds(300))

            let rep = try #require(render(view))
            #expect(eyeInk(rep) > eyeInk(control) / 2,
                    "\(next) after an interrupted sleep: the eyes are missing")
        }
    }

    /// The glint turns round when the hare looks the other way, however fast
    /// the picker reports.
    ///
    /// The turn happens behind a blink, 92 ms in. The picker reports every few
    /// dozen milliseconds and each report used to be a `setState`, which
    /// cancels running sequences — the turn among them — so the eyes crossed
    /// over with the light still on the side they were looking at.
    @Test func theGlintTurnsRoundUnderAStreamOfReports() async throws {
        let settled = hare()
        settled.setState(.colorPicking(.rightCenter))
        let lookingRight = try glint(of: settled)

        let view = hare()
        view.setState(.colorPicking(.leftCenter))
        #expect(abs(try glint(of: view) - lookingRight) > 0.05,
                "the two gazes draw the same eye: this proves nothing")

        for _ in 0..<12 {
            view.look(towardX: 0.8, y: 0.5)
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(200))

        #expect(abs(try glint(of: view) - lookingRight) < 0.01,
                "the eyes look right with the glint of an eye looking left")
        #expect(abs(try leftEye(of: view).span.lowerBound
                    - leftEye(of: settled).span.lowerBound) < 0.01,
                "the eyes did not end up where a right gaze puts them")
    }

    /// Outside a pick the cursor is nobody's news: it neither opens a sleeping
    /// hare's eyes nor turns them.
    @Test func theCursorOnlyCountsWhilePicking() {
        let view = hare()
        view.setState(.sleeping)
        view.look(towardX: 0.9, y: 0.9)
        for eye in view.eyeLayersForTesting {
            #expect((eye.fillColor?.alpha ?? 0) == 0, "a cursor report opened a sleeping hare's eyes")
        }
    }

    /// Only an awake hare follows the pointer.
    ///
    /// Every other state used to inherit whatever the last one left running:
    /// after a screenshot the hare celebrated, shut its eyes for sleep — and
    /// its ears went on following the pointer, fifteen times a second, until
    /// the panel next opened and closed.
    @Test func onlyAnAwakeHareFollowsThePointer() {
        let view = hare()
        for state in [MascotState.awake, .celebrating, .awake, .countdown, .awake,
                      .colorPicking(.leftUp), .awake, .waiting, .awake, .sleeping] {
            view.setState(state)
            #expect(view.followsPointerForTesting == (state == .awake),
                    "\(state) \(view.followsPointerForTesting ? "follows" : "ignores") the pointer")
        }
    }

    /// Into the wait and out of it without a jump.
    ///
    /// The wait is a loop on the body's path, and it began upright whatever
    /// the ears were doing, so a leaning hare snapped straight up; taken off
    /// again, the loop left the body on its model path at once, so the ears
    /// jumped from mid-stretch to wherever they had been before. Read off the
    /// screen — the presentation — since the model never jumps at all.
    @Test func theWaitTakesTheEarsFromWhereTheyAre() async throws {
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 22, height: 18),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let view = hare()
        window.contentView = view
        window.alphaValue = 0.01
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let upright = MascotArtwork.agreeing(named: "earsUp")
            .applying(MascotStatusView.artworkToViewForTesting).cgPath

        // A pose to start from that the pointer has no say in.
        view.setState(.colorPicking(.leftCenter))
        try await Task.sleep(for: .milliseconds(300))
        let leaning = try #require(view.shownBodyForTesting)
        let lean = try farthest(leaning, upright)
        #expect(lean > 1, "the pose to start from is upright already: this proves nothing")

        view.setState(.waiting)
        try await Task.sleep(for: .milliseconds(15))
        let entering = try farthest(try #require(view.shownBodyForTesting), leaning)
        #expect(entering < lean / 3, "the wait snapped the ears upright (\(entering) of \(lean) pt)")

        // Leave mid-stretch, when a jump would be largest: waited for rather
        // than timed, so a slow machine cannot land the check on an upright
        // moment of the loop. Not before the ears have settled into the loop,
        // though — on the way there they are far from upright too, and moving
        // on their own.
        try await Task.sleep(for: .milliseconds(300))
        var stretched = try #require(view.shownBodyForTesting)
        var stretch: CGFloat = 0
        for _ in 0..<150 where stretch <= 1 {
            try await Task.sleep(for: .milliseconds(20))
            stretched = try #require(view.shownBodyForTesting)
            stretch = try farthest(stretched, upright)
        }
        #expect(stretch > 1, "the loop is not moving the ears: this proves nothing")

        // Out into a celebration, which has nothing of its own to say about the
        // body for the first half second — so whatever the body does now is the
        // wait letting go. (Awake would hide a jump: the pointer takes the body
        // straight away, from what is on screen.)
        view.setState(.celebrating)
        try await Task.sleep(for: .milliseconds(15))
        let leaving = try farthest(try #require(view.shownBodyForTesting), stretched)
        #expect(leaving < stretch / 3, "leaving the wait snapped the ears (\(leaving) of \(stretch) pt)")
    }

    /// The farthest any point of one pose is from its opposite number in the
    /// other. The poses agree, so every point has one.
    private func farthest(_ a: CGPath, _ b: CGPath) throws -> CGFloat {
        func points(_ path: CGPath) -> [CGPoint] {
            var all: [CGPoint] = []
            path.applyWithBlock { element in
                let count: Int
                switch element.pointee.type {
                case .moveToPoint, .addLineToPoint: count = 1
                case .addQuadCurveToPoint:          count = 2
                case .addCurveToPoint:              count = 3
                default:                            count = 0
                }
                for i in 0..<count { all.append(element.pointee.points[i]) }
            }
            return all
        }
        let (pa, pb) = (points(a), points(b))
        try #require(pa.count == pb.count, "the two paths do not agree")
        return zip(pa, pb).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
    }
}

/// Where the eyes look while the colour picker is out.
@MainActor @Suite struct EyeDirectionTests {

    /// The middle of the screen is sticky: a picker resting on it made the
    /// hare blink at every jitter, since each change of side is a blink.
    @Test func turningRoundTakesMoreThanTouchingTheMiddle() {
        #expect(EyeDirection.toward(x: 0.52, y: 0.5, from: .leftCenter) == .leftCenter)
        #expect(EyeDirection.toward(x: 0.48, y: 0.5, from: .rightCenter) == .rightCenter)
        #expect(EyeDirection.toward(x: 0.56, y: 0.5, from: .leftCenter) == .rightCenter)
        #expect(EyeDirection.toward(x: 0.44, y: 0.5, from: .rightCenter) == .leftCenter)
        // With nowhere to turn from, the middle is simply the middle.
        #expect(EyeDirection.toward(x: 0.49, y: 0.5, from: nil) == .leftCenter)
        #expect(EyeDirection.toward(x: 0.51, y: 0.5, from: nil) == .rightCenter)
    }

    @Test func soAreTheRows() {
        #expect(EyeDirection.toward(x: 0.2, y: 0.68, from: .leftCenter) == .leftCenter)
        #expect(EyeDirection.toward(x: 0.2, y: 0.70, from: .leftCenter) == .leftUp)
        #expect(EyeDirection.toward(x: 0.2, y: 0.64, from: .leftUp) == .leftUp)
        #expect(EyeDirection.toward(x: 0.2, y: 0.62, from: .leftUp) == .leftCenter)
        #expect(EyeDirection.toward(x: 0.2, y: 0.31, from: .leftCenter) == .leftCenter)
        #expect(EyeDirection.toward(x: 0.2, y: 0.29, from: .leftCenter) == .leftDown)
        #expect(EyeDirection.toward(x: 0.2, y: 0.35, from: .leftDown) == .leftDown)
        #expect(EyeDirection.toward(x: 0.2, y: 0.37, from: .leftDown) == .leftCenter)
        // A long way off lands in one step, both ways at once.
        #expect(EyeDirection.toward(x: 0.9, y: 0.9, from: .leftDown) == .rightUp)
    }
}

/// What the panel tells the mascot.
@MainActor @Suite struct MascotPanelNewsTests {

    /// The panel hides *for* the colour picker, and that is not sleep. Posted
    /// as sleep, it shut the hare's eyes a moment into the pick.
    @Test func hidingForThePickerIsNotSleep() {
        #expect(NotchPanelController.mascotState(for: .hidden, colorPickerInFlight: true) == nil)
        #expect(NotchPanelController.mascotState(for: .hidden, colorPickerInFlight: false) == .sleeping)
    }

    @Test func everyOtherStateSaysWhatItAlwaysSaid() {
        for inFlight in [false, true] {
            func news(_ state: PanelState) -> MascotState? {
                NotchPanelController.mascotState(for: state, colorPickerInFlight: inFlight)
            }
            #expect(news(.main) == .awake)
            #expect(news(.archive) == .awake)
            #expect(news(.showing) == .awake)
            #expect(news(.waiting) == .waiting)
            #expect(news(.countdown) == .countdown)
            #expect(news(.hiding) == nil)
            #expect(news(.translate) == nil)
        }
    }
}
