import AppKit
import QuartzCore

// MARK: - Public types

enum EyeDirection: Equatable {
    case leftUp, leftCenter, leftDown
    case rightUp, rightCenter, rightDown

    var isLeft: Bool {
        switch self {
        case .leftCenter, .leftUp, .leftDown:    return true
        case .rightCenter, .rightUp, .rightDown: return false
        }
    }

    private enum Row { case up, center, down }

    private var row: Row {
        switch self {
        case .leftUp, .rightUp:         return .up
        case .leftCenter, .rightCenter: return .center
        case .leftDown, .rightDown:     return .down
        }
    }

    private init(isLeft: Bool, row: Row) {
        switch row {
        case .up:     self = isLeft ? .leftUp : .rightUp
        case .center: self = isLeft ? .leftCenter : .rightCenter
        case .down:   self = isLeft ? .leftDown : .rightDown
        }
    }

    /// Which way to look at a place on the screen — `x` and `y` from 0 to 1,
    /// y up — given which way the eyes look already.
    ///
    /// The lines between directions are sticky: to change sides the pointer
    /// has to go a little past the line, not merely touch it. Every change of
    /// side is a blink, since the glint turns round behind one, and a picker
    /// resting on the middle of the screen made the hare blink at each jitter.
    static func toward(x: CGFloat, y: CGFloat, from previous: EyeDirection?) -> EyeDirection {
        let side: CGFloat = 0.04, rowGap: CGFloat = 0.03
        // Each line moves away from the side the eyes are on, so staying is
        // easier than crossing.
        let middle: CGFloat
        switch previous?.isLeft {
        case true?:  middle = 0.5 + side
        case false?: middle = 0.5 - side
        case nil:    middle = 0.5
        }
        let upLine: CGFloat, downLine: CGFloat
        switch previous?.row {
        case .up?:     upLine = 0.66 - rowGap; downLine = 0.33 - rowGap
        case .center?: upLine = 0.66 + rowGap; downLine = 0.33 - rowGap
        case .down?:   upLine = 0.66 + rowGap; downLine = 0.33 + rowGap
        case nil:      upLine = 0.66;          downLine = 0.33
        }
        let row: Row = y > upLine ? .up : (y < downLine ? .down : .center)
        return EyeDirection(isLeft: x < middle, row: row)
    }
}

enum MascotState: Equatable {
    case sleeping
    case awake
    /// Something the app started is running — a translation, a save, an
    /// update. The ears spread and hold, which is what listening looks like.
    case waiting
    case colorPicking(EyeDirection)
    case celebrating
    case countdown
}

// MARK: - MascotStatusView

/// Menu-bar mascot. View size: 22 × 18 pt (y = 0 at bottom, CALayer convention).
/// Body outlines come straight from the Figma 22.18×18 export.
final class MascotStatusView: NSView {

    // MARK: Layers

    private let bodyLayer        = CAShapeLayer()
    private let leftEyeLayer     = CAShapeLayer()
    private let rightEyeLayer    = CAShapeLayer()

    // MARK: Geometry (all in CALayer coords: y from bottom, view 22×18)

    /// Everything is stated in the artwork's own box — 12 × 12, y downward,
    /// exactly as Figma drew it — and mapped into the view at the last moment.
    ///
    /// The view is 22 × 18 because that is the room a status item gives; the
    /// hare is 11 points tall and stands about ten of them, centred. Keeping
    /// the numbers in the artwork's units is what lets a pose be swapped for
    /// another without re-deriving a single coordinate: the drawing and the
    /// places its eyes go are in the same space.
    private enum G {
        /// How tall the hare stands, in the eighteen points the status item
        /// gives. Ten was the artwork's own size and read as a small mark in
        /// the menu bar beside everything else; the body this replaced filled
        /// its box, and so does this one — with a point of air above the ears
        /// and below the feet.
        static let bodyHeight: CGFloat = 15.5
        static let scale: CGFloat = bodyHeight / 11

        /// Artwork (y down, 12 × 12) into the view (y up, 22 × 18), centred.
        static let toView: CGAffineTransform = {
            let drawn = MascotArtwork.side * scale
            let inset = (CGSize(width: 22, height: 18).width - drawn) / 2
            let top = (18 - drawn) / 2 + drawn
            return CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: inset, ty: top)
        }()

        /// The same mapping about an eye's own centre: `toView` without its
        /// offset. An eye is drawn around the origin and put in place by its
        /// layer's position, because a layer scales about its position — and
        /// every blink, pop and squeeze is a scale.
        static let aboutEye = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: 0, ty: 0)

        /// Where the eyes sit, in artwork units, and how far the gaze moves
        /// them. The row is the artwork's own; the travel is what a two-point
        /// eye has room for without leaving the face.
        static let eyeRow = MascotArtwork.Eye.left.y
        static let eyeGap: CGFloat = 0.9      // sideways, per gaze
        static let eyeRise: CGFloat = 0.55    // up or down, per gaze

        /// The open eye, kept from the drawing before this one: a rounded shape
        /// with its glint carved out rather than drawn on. Two artwork points
        /// wide, which is what the new body has room for.
        static let eyeW: CGFloat = 2
        static let eyeH: CGFloat = 2

        /// The closed eye, as the artwork draws it.
        static let closedEyeWidth: CGFloat = 1.5
    }

    // MARK: State

    private var state: MascotState = .sleeping
    private var eyesOpen     = false
    private var sequenceGen  = 0
    private var blinkTimer:  Timer?

    /// Direction the eyes were in the last time they were open.
    /// Used to reopen eyes at the same position after sleep, and to drive
    /// the celebrating sequence without an external hint from NotchHoverController.
    private var lastOpenDirection: EyeDirection = .leftCenter

    /// leftSeries value of the most recent sleep lines.
    /// Used to reopen eyes on the same horizontal side after waking up.
    private var lastArcIsLeft: Bool = true

    private var ink: CGColor = CGColor(gray: 0.05, alpha: 1)

    /// Which side of the eye the glint sits on. It is a highlight, not a
    /// pupil, so it belongs away from what the hare is looking at — but it may
    /// only change while the eyes are shut, or it reads as a flip.
    private var glintOnTheRight = true
    /// Where the pointer is, from −1 (far to the left of the mascot) to +1.
    /// The ear nearest it folds away: an ear is the one part of a hare that
    /// points at what has its attention. Nil until the first reading, so the
    /// first one is always applied, whatever the body was doing before.
    private var lean: CGFloat?
    private var pointerTimer: Timer?
    /// True while a loop owns the body — the wait's spread ears, or the idle
    /// flick — so the pointer does not fight it for the same layer.
    private var bodyIsLooping = false

    /// What the body is drawing right now — for the test that compares it with
    /// the artwork it is supposed to be drawing.
    var bodyPathForTesting: CGPath? { bodyLayer.path }
    /// What the body is showing on screen this moment, mid-animation included.
    var shownBodyForTesting: CGPath? { bodyLayer.presentation()?.path }
    /// The one transform that takes the artwork's box into the view, so a test
    /// can ask about a place on the hare rather than about a pixel.
    static var artworkToViewForTesting: CGAffineTransform { G.toView }
    /// The eyes as drawn, in the view's coordinates.
    var eyePathsForTesting: (CGPath?, CGPath?) { (drawn(leftEyeLayer), drawn(rightEyeLayer)) }
    var eyeLayersForTesting: [CAShapeLayer] { [leftEyeLayer, rightEyeLayer] }
    var followsPointerForTesting: Bool { pointerTimer != nil }

    private func drawn(_ eye: CAShapeLayer) -> CGPath? {
        var place = CGAffineTransform(translationX: eye.position.x, y: eye.position.y)
        return eye.path?.copy(using: &place)
    }

    // MARK: Poses

    /// Every pose in view coordinates, ready to be handed to a layer.
    ///
    /// Built once: the agreement between them — same anchors, in the same
    /// places along the outline — is arithmetic nobody should pay for twice,
    /// and it is what lets any pose morph into any other.
    private static let poses: [String: CGPath] = {
        var built: [String: CGPath] = [:]
        for (name, path) in MascotArtwork.agreeingPaths() {
            built[name] = path.applying(G.toView).cgPath
        }
        return built
    }()

    private static func pose(_ name: String) -> CGPath {
        poses[name] ?? poses["earsUp"] ?? CGMutablePath()
    }

    /// The body as the pointer leaves it: upright in the middle, one ear
    /// folded away as the pointer goes to that side. Continuous, because the
    /// pointer is — a lean that snapped between three poses would read as a
    /// twitch rather than as attention.
    private static func leaning(_ lean: CGFloat) -> CGPath {
        let up = MascotArtwork.agreeing(named: "earsUp")
        guard abs(lean) > 0.01 else { return up.applying(G.toView).cgPath }
        let side = MascotArtwork.agreeing(named: lean < 0 ? "earFoldedLeft" : "earFoldedRight")
        let between = up.interpolated(to: side, at: min(1, abs(lean))) ?? up
        return between.applying(G.toView).cgPath
    }

    /// The pose a gaze leans into: the ear nearest what the hare is looking at
    /// folds away, which is what an ear does and what makes the head read as
    /// turned. Asleep it is neither — both ears up.
    private static func pose(forGaze direction: EyeDirection?) -> CGPath {
        guard let direction else { return pose("earsUp") }
        return pose(direction.isLeft ? "earFoldedLeft" : "earFoldedRight")
    }

    // MARK: Init

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }
    isolated deinit {
        blinkTimer?.invalidate()
        // A repeating timer belongs to the run loop, not to the view: left
        // alone it would go on firing fifteen times a second for nobody.
        pointerTimer?.invalidate()
    }

    // MARK: Setup

    private func setup() {
        wantsLayer = true

        // Body — exact Figma outlines: rectangle-ish squircle at rest, organic
        // trapezoid variants when the mascot looks up/down (perspective metaphor).
        // All three paths share the same segment structure, so CoreAnimation
        // morphs between them cleanly.
        bodyLayer.path      = MascotStatusView.pose("earsUp")
        bodyLayer.fillColor = .clear
        bodyLayer.lineWidth = G.scale
        // Round, because the outline has a sharp notch between the ears and a
        // shape layer joins with a miter by default: two nearly parallel lines
        // meeting there grew a spike ten line-widths long, straight down the
        // hare's face. The body it replaced was a squircle and never met the
        // limit, so nothing had asked the question before.
        bodyLayer.lineJoin = .round
        bodyLayer.lineCap = .round
        layer!.addSublayer(bodyLayer)

        // Eye layers
        for eye in [leftEyeLayer, rightEyeLayer] {
            eye.lineWidth  = 0.8 * G.scale
            eye.lineCap    = .round
            eye.fillColor  = .clear
            eye.strokeColor = .clear
            layer!.addSublayer(eye)
        }

        refreshColors()
        // Start sleeping (no animation on first draw)
        applyArcs(leftSeries: Bool.random())
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ink = dark ? CGColor(gray: 1.0, alpha: 0.88) : CGColor(gray: 0.05, alpha: 1.0)

        noAnim {
            self.bodyLayer.strokeColor = self.ink
            // Each eye in whatever it is drawn with right now — a wink has one
            // of each, and an eye being squeezed shut is still filled.
            for eye in [self.leftEyeLayer, self.rightEyeLayer] {
                if (eye.fillColor?.alpha ?? 0) > 0 { eye.fillColor = self.ink }
                if (eye.strokeColor?.alpha ?? 0) > 0 { eye.strokeColor = self.ink }
            }
        }
    }

    // MARK: - Pointer

    /// Follows the pointer while the hare is awake, and lets go in every other
    /// state. Celebrating used to keep the timer the panel had started: the
    /// hare shut its eyes for sleep and its ears went on following the
    /// pointer, fifteen times a second, until the panel next opened and closed.
    ///
    /// Polled rather than monitored: a global event monitor wakes this process
    /// for every mouse move on the machine, and what is wanted here is a lean
    /// that settles — fifteen times a second is finer than an ear can be seen
    /// to move.
    private func followPointer(_ follow: Bool) {
        guard follow != (pointerTimer != nil) else { return }
        pointerTimer?.invalidate()
        pointerTimer = nil
        lean = nil
        guard follow else { return }
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in self?.readPointer() }
        }
        readPointer()
    }

    private func readPointer() {
        guard !bodyIsLooping, let window else { return }
        let centre = window.convertPoint(toScreen: convert(CGPoint(x: bounds.midX,
                                                                   y: bounds.midY), to: nil))
        // Fully leant a third of a screen away; nearer than that it is partial,
        // which is what makes it read as following rather than as snapping.
        let reach = (window.screen ?? NSScreen.main)?.frame.width ?? 1440
        let wanted = max(-1, min(1, (NSEvent.mouseLocation.x - centre.x) / (reach / 3)))
        if let lean, abs(wanted - lean) <= 0.02 { return }
        // The first reading comes from whatever pose another state left, which
        // can be a long way off: give that journey a little longer.
        let duration = lean == nil ? 0.25 : 0.12
        lean = wanted
        animPath(bodyLayer, to: Self.leaning(wanted), dur: duration)
    }

    // MARK: - Public

    func setState(_ state: MascotState) {
        self.state = state
        bumpGen()
        blinkTimer?.invalidate()
        blinkTimer = nil
        if state != .waiting { releaseBody() }
        followPointer(state == .awake)

        switch state {
        case .sleeping:
            if eyesOpen {
                let gen = sequenceGen
                animateSqueeze {
                    guard self.sequenceGen == gen else { return }
                    self.applyArcs(leftSeries: self.lastOpenDirection.isLeft)
                }
            } else {
                applyArcs(leftSeries: lastOpenDirection.isLeft)
            }

        case .awake:
            let dir: EyeDirection = lastArcIsLeft ? .leftCenter : .rightCenter
            if !eyesOpen { applyOpenEyes(dir: dir, popAnim: true) }
            scheduleNextBlink()

        case .waiting:
            let dir: EyeDirection = lastArcIsLeft ? .leftCenter : .rightCenter
            if !eyesOpen { applyOpenEyes(dir: dir, popAnim: true) }
            scheduleNextBlink()
            spreadEars()

        case .colorPicking(let dir):
            if !eyesOpen {
                applyOpenEyes(dir: dir, popAnim: true)
            } else {
                animateMoveEyes(to: dir, duration: 0.15)
            }

        case .celebrating:
            let celebDir  = lastOpenDirection        // capture now; closures must not re-read
            let celebLeft = lastOpenDirection.isLeft
            if !eyesOpen { applyOpenEyes(dir: celebDir, popAnim: false) }
            let gen = sequenceGen
            applyWink(leftWinks: !celebLeft)
            after(0.45, gen: gen) { self.applyOpenEyes(dir: celebDir, popAnim: false) }
            after(0.65, gen: gen) { self.animateBlink() }
            after(1.0,  gen: gen) { self.animateBlink() }
            after(1.5,  gen: gen) {
                let g2 = self.bumpGen()
                self.animateSqueeze {
                    guard self.sequenceGen == g2 else { return }
                    self.applyArcs(leftSeries: celebLeft)
                }
            }

        case .countdown:
            let dir: EyeDirection = lastArcIsLeft ? .leftCenter : .rightCenter
            if !eyesOpen { applyOpenEyes(dir: dir, popAnim: true) }
            animateMoveEyes(to: .leftDown, duration: 0.2)
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.animateBlink()
                }
            }
        }
    }

    /// The picker's cursor, as a place on its screen: `x` and `y` from 0 to 1,
    /// y up.
    ///
    /// Not a change of state. The sampler reports every few dozen
    /// milliseconds, and each `setState` restarts the sequences — so the blink
    /// that turns the glint round while the eyes are shut was cancelled by the
    /// very next report, and the light stayed on the side the hare was looking
    /// at. Only a change of direction does anything here, and only while the
    /// picker has the hare's attention.
    func look(towardX x: CGFloat, y: CGFloat) {
        guard case .colorPicking(let current) = state else { return }
        let dir = EyeDirection.toward(x: x, y: y, from: current)
        guard dir != current else { return }
        state = .colorPicking(dir)
        if eyesOpen {
            animateMoveEyes(to: dir, duration: 0.15)
        } else {
            applyOpenEyes(dir: dir, popAnim: true)
        }
    }

    /// The wait: ears spread, held, and let go again — over and over, slowly.
    /// The same two poses the pointer uses would be a twitch; this is a breath.
    private func spreadEars() {
        // Already waiting: a second post of the same news lets the loop run on
        // rather than starting it over.
        guard !bodyIsLooping else { return }
        // Into the loop from wherever the ears are. The loop begins upright,
        // and started at once it snapped a leaning hare straight up.
        let settle: CFTimeInterval = 0.25
        animPath(bodyLayer, to: Self.pose("earsUp"), dur: settle)
        bodyIsLooping = true
        let loop = CAKeyframeAnimation(keyPath: "path")
        loop.values = [Self.pose("earsUp"), Self.pose("earsSpreadRight"),
                       Self.pose("earsUp"), Self.pose("earsSpreadLeft"),
                       Self.pose("earsUp")]
        loop.keyTimes = [0, 0.22, 0.44, 0.66, 1]
        loop.duration = 2.6
        loop.repeatCount = .infinity
        loop.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut),
                                     count: 4)
        loop.beginTime = bodyLayer.convertTime(CACurrentMediaTime(), from: nil) + settle
        bodyLayer.add(loop, forKey: "loop")
    }

    /// Takes the body back from the wait's loop, from wherever the loop had
    /// the ears. Removing the loop alone put the body back on its model path
    /// at once — a jump from the middle of a stretch to wherever the ears had
    /// been before the wait. The ears settle upright from there; a state that
    /// wants another pose starts its own journey from the same place.
    private func releaseBody() {
        guard bodyIsLooping else { return }
        bodyIsLooping = false
        let shown = bodyLayer.presentation()?.path
        bodyLayer.removeAnimation(forKey: "loop")
        animPath(bodyLayer, from: shown, to: Self.pose("earsUp"), dur: 0.25)
    }

    // MARK: - Drawing helpers

    /// Show sleep arcs on both eyes. Resets all transforms.
    private func applyArcs(leftSeries: Bool) {
        eyesOpen = false
        lastArcIsLeft = leftSeries
        setBodyShape(for: nil, duration: 0.15)
        let (lc, rc) = eyeConfig(leftSeries ? .leftCenter : .rightCenter)
        place(leftEyeLayer, at: lc)
        place(rightEyeLayer, at: rc)

        for eye in [leftEyeLayer, rightEyeLayer] {
            // Whatever was closing or opening them is over: an arc is shut.
            for key in ["squeeze", "blink", "pop"] { eye.removeAnimation(forKey: key) }
        }
        noAnim {
            for eye in [self.leftEyeLayer, self.rightEyeLayer] {
                // Reset any scale transform left over from squeeze / pop
                eye.transform   = CATransform3DIdentity
                eye.path        = self.closedEyePath()
                eye.fillColor   = .clear
                eye.strokeColor = self.ink
            }
        }
    }

    /// Set open-eye glint-carved paths, optionally animating a spring pop.
    private func applyOpenEyes(dir: EyeDirection, popAnim: Bool) {
        eyesOpen = true
        lastOpenDirection = dir
        // They were shut a moment ago, so the light may take its new side now.
        glintOnTheRight = dir.isLeft
        setBodyShape(for: dir, duration: 0.15)
        let (lc, rc) = eyeConfig(dir)
        place(leftEyeLayer, at: lc)
        place(rightEyeLayer, at: rc)

        for eye in [leftEyeLayer, rightEyeLayer] {
            // A squeeze cut short by this very call would go on shutting them.
            eye.removeAnimation(forKey: "squeeze")
        }
        noAnim {
            for eye in [self.leftEyeLayer, self.rightEyeLayer] {
                eye.transform   = CATransform3DIdentity
                eye.path        = self.eyePath()
                eye.fillColor   = self.ink
                eye.strokeColor = .clear
            }
        }

        if popAnim {
            // Scales about the eye's own centre, which is its position — see
            // `G.aboutEye`. The model stays at 1, so that is what shows when
            // the spring is done.
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0
            spring.toValue   = 1
            spring.stiffness = 280
            spring.damping   = 18
            spring.duration  = spring.settlingDuration
            leftEyeLayer.add(spring,  forKey: "pop")
            rightEyeLayer.add(spring, forKey: "pop")
        }
    }

    /// Apply wink: one eye closes to a sleep arc, the other stays open.
    /// leftWinks=true  → right-series in play, left eye squints
    /// leftWinks=false → left-series in play, right eye squints
    private func applyWink(leftWinks: Bool) {
        let (lc, rc) = eyeConfig(leftWinks ? .rightCenter : .leftCenter)
        place(leftEyeLayer, at: lc)
        place(rightEyeLayer, at: rc)
        let (shut, open) = leftWinks ? (leftEyeLayer, rightEyeLayer)
                                     : (rightEyeLayer, leftEyeLayer)
        noAnim {
            shut.path        = self.closedEyePath()
            shut.fillColor   = .clear
            shut.strokeColor = self.ink
            open.path        = self.eyePath()
            open.fillColor   = self.ink
            open.strokeColor = .clear
        }
    }

    /// Puts an eye where it belongs at once, ending any journey it was on.
    /// The centre is in artwork units, like everything else about the hare.
    private func place(_ eye: CAShapeLayer, at centre: CGPoint) {
        eye.removeAnimation(forKey: "movePos")
        noAnim { eye.position = centre.applying(G.toView) }
    }

    // MARK: - Eye movement

    private func animateMoveEyes(to dir: EyeDirection, duration: CFTimeInterval) {
        // Looking the other way means the glint changes sides, and a glint that
        // moves in plain sight reads as the eye flipping over. So the eyes
        // blink on the way: they shut, the light changes side while nobody can
        // see it, and they open looking the other way. Which is also what a
        // hare does when it turns its head.
        let crossing = dir.isLeft != lastOpenDirection.isLeft
        lastOpenDirection = dir
        setBodyShape(for: dir, duration: duration)

        guard crossing, eyesOpen else {
            let (lc, rc) = eyeConfig(dir)
            animPos(leftEyeLayer,  to: lc.applying(G.toView), dur: duration)
            animPos(rightEyeLayer, to: rc.applying(G.toView), dur: duration)
            return
        }

        // The eyes open on wherever they are asked to look by then, not on
        // where they were asked when they shut: the picker keeps reporting
        // through the blink, and a turn it asked for in the dark is still
        // wanted.
        let gen = sequenceGen
        blink { [weak self] in
            guard let self, self.sequenceGen == gen, self.eyesOpen else { return }
            let now = self.lastOpenDirection
            self.glintOnTheRight = now.isLeft
            let (lc, rc) = self.eyeConfig(now)
            self.place(self.leftEyeLayer, at: lc)
            self.place(self.rightEyeLayer, at: rc)
            self.noAnim {
                self.leftEyeLayer.path = self.eyePath()
                self.rightEyeLayer.path = self.eyePath()
            }
        }
    }

    /// One blink, with something done at the moment the eyes are shut.
    private func blink(atTheClosedMoment change: @escaping @MainActor () -> Void) {
        let shut = CAKeyframeAnimation(keyPath: "transform.scale.y")
        shut.values   = [1.0, 0.05, 1.0]
        shut.keyTimes = [0, 0.42, 1.0]
        shut.duration = 0.22
        shut.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        leftEyeLayer.add(shut,  forKey: "blink")
        rightEyeLayer.add(shut, forKey: "blink")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(92))   // shut
            change()
        }
    }

    // MARK: - Blink / squeeze

    /// Schedule the next idle blink with a random delay so it feels natural.
    /// Recursively re-arms itself; stops when eyes close (eyesOpen == false).
    private func scheduleNextBlink() {
        guard eyesOpen else { return }
        let delay = TimeInterval.random(in: 2.5...5.0)
        blinkTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.eyesOpen else { return }
                self.animateBlink()
                self.scheduleNextBlink()
            }
        }
    }

    private func animateBlink() {
        let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
        a.values   = [1.0, 0.05, 1.0]
        a.keyTimes = [0, 0.35, 1.0]
        a.duration = 0.18
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        leftEyeLayer.add(a,  forKey: "blink")
        rightEyeLayer.add(a, forKey: "blink")
    }

    /// Squeeze both eyes to scale.y = 0, then call completion.
    ///
    /// The eyes count as shut from the first moment. The model goes to zero
    /// here and only the completion puts the arcs up, so a state arriving in
    /// between — and cancelling the completion — used to find the eyes still
    /// "open", leave them alone, and keep a hare with no eyes at all.
    private func animateSqueeze(completion: @escaping @MainActor () -> Void) {
        eyesOpen = false
        // Correct pattern: set model → animate from current presentation → model
        let fromY = (leftEyeLayer.presentation()?.value(forKeyPath: "transform.scale.y") as? CGFloat) ?? 1

        // Set model to 0 so when animation ends, 0 is shown (lines will reset to 1 right after)
        noAnim {
            self.leftEyeLayer.setValue(CGFloat(0), forKeyPath: "transform.scale.y")
            self.rightEyeLayer.setValue(CGFloat(0), forKeyPath: "transform.scale.y")
        }

        let a = CABasicAnimation(keyPath: "transform.scale.y")
        a.fromValue = fromY
        a.toValue   = 0
        a.duration  = 0.12
        a.timingFunction = CAMediaTimingFunction(name: .easeIn)
        leftEyeLayer.add(a,  forKey: "squeeze")
        rightEyeLayer.add(a, forKey: "squeeze")

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(130))
            completion()
        }
    }

    // MARK: - Low-level animation helpers

    /// `from` is what is on screen unless said otherwise — which it must be
    /// when an animation has just been taken off the layer, since what that
    /// animation was showing is exactly where the journey starts.
    private func animPath(_ layer: CAShapeLayer, from shown: CGPath? = nil,
                          to path: CGPath, dur: CFTimeInterval) {
        let from = shown ?? layer.presentation()?.path ?? layer.path
        // Set model first
        noAnim { layer.path = path }
        let a = CABasicAnimation(keyPath: "path")
        a.fromValue = from
        a.toValue   = path
        a.duration  = dur
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: "movePath")
    }

    private func animPos(_ layer: CALayer, to pos: CGPoint, dur: CFTimeInterval) {
        let from = layer.presentation()?.position ?? layer.position
        noAnim { layer.position = pos }
        let a = CABasicAnimation(keyPath: "position")
        a.fromValue = from
        a.toValue   = pos
        a.duration  = dur
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: "movePos")
    }

    // MARK: - Eye paths (exact Figma geometry)

    /// Open-eye outline, drawn around the origin — the layer's position is
    /// where the eye is.
    ///
    /// The eye is a single filled shape with the highlight *carved out* of the
    /// fill (negative space, per Figma) — not a light pupil drawn on top.
    /// Figma's static states mirror the glint per gaze direction, but in
    /// motion that reads as the eyes flip-flopping. Instead one constant shape
    /// translates with the gaze, so the glint moves like a pupil — gaze
    /// changes are pure movement, never a flip.
    private func eyePath() -> CGPath {
        // The artwork's own eye: two points across, with a small bite taken out
        // of its side for the glint. The eye this replaces was three by four,
        // drawn for a body twice this size — squeezed down to two points its
        // glint ate the pupil and what was left read as the letter C.
        // One shape, mirrored only while the eyes are shut — see
        // `animateMoveEyes`. A glint that flips in plain sight reads as the
        // eyes flip-flopping, which is why the drawing before this one kept a
        // single shape and simply moved it.
        let half = G.eyeW / 2
        let eye = glintOnTheRight ? Self.openEye : Self.openEye.mirrored(in: G.eyeW)
        let centred = CGAffineTransform(translationX: -half, y: -half)
        let p = CGMutablePath()
        p.addPath(eye.cgPath, transform: centred.concatenating(G.aboutEye))
        return p
    }

    /// Parsed once: the eye is the same drawing wherever it is put.
    private static let openEye: VectorPath = {
        VectorPath.parse(MascotArtwork.Eye.open.replacingOccurrences(of: "\n", with: ""))
            ?? VectorPath(segments: [])
    }()

    /// The closed eye — the little arc the artwork draws for sleep — around
    /// the origin, like the open one.
    private func closedEyePath() -> CGPath {
        let half = G.closedEyeWidth / 2
        let p = CGMutablePath()
        let t = CGAffineTransform(translationX: -half, y: -0.15)
            .concatenating(G.aboutEye)
        let arc = CGMutablePath()
        arc.move(to: CGPoint(x: 0, y: 0.25))
        arc.addCurve(to: CGPoint(x: 1.5, y: 0.25),
                     control1: CGPoint(x: 0.375, y: 0),
                     control2: CGPoint(x: 1.125, y: 0))
        p.addPath(arc, transform: t)
        return p
    }

    // MARK: - Eye config

    /// Eye-box centers per gaze. Glint shape is constant across states — only
    /// the eye position tracks the gaze (left/right series + up/center/down).
    private func eyeConfig(_ dir: EyeDirection) -> (lEye: CGPoint, rEye: CGPoint) {
        let sideways: CGFloat = dir.isLeft ? -G.eyeGap : G.eyeGap
        let rise: CGFloat
        switch dir {
        case .leftUp, .rightUp:         rise = -G.eyeRise
        case .leftDown, .rightDown:     rise = G.eyeRise
        case .leftCenter, .rightCenter: rise = 0
        }
        let y = G.eyeRow + rise
        return (CGPoint(x: MascotArtwork.Eye.left.x + sideways, y: y),
                CGPoint(x: MascotArtwork.Eye.right.x + sideways, y: y))
    }

    // MARK: - Sequence helpers

    @discardableResult
    private func bumpGen() -> Int {
        sequenceGen &+= 1
        return sequenceGen
    }

    private func after(_ delay: TimeInterval, gen: Int,
                       action: @escaping @MainActor () -> Void) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.sequenceGen == gen else { return }
            action()
        }
    }

    // MARK: - CATransaction shorthand

    private func noAnim(_ block: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        block()
        CATransaction.commit()
    }

    // MARK: - Body paths (exact Figma geometry, node 1087:* — 22.18×18 export)

    /// Morph the body outline to match a 2-axis gaze direction (nil = sleep).
    /// The five outlines share an identical segment structure
    /// (move + line + 6 cubics + line + 6 cubics), so CoreAnimation
    /// interpolates between any pair cleanly.
    private func setBodyShape(for dir: EyeDirection?, duration: CFTimeInterval) {
        // While the pointer or a loop owns the body, the gaze does not move it:
        // two things writing one layer is a fight nobody wins.
        guard !bodyIsLooping, pointerTimer == nil else { return }
        let target = Self.pose(forGaze: dir)
        if duration <= 0 {
            noAnim { self.bodyLayer.path = target }
        } else {
            animPath(bodyLayer, to: target, dur: duration)
        }
    }

}
