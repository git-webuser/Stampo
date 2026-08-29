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
        /// The hare drawn ten points tall, out of the eleven it is.
        static let scale: CGFloat = 10.0 / 11.0

        /// Artwork (y down, 12 × 12) into the view (y up, 22 × 18), centred.
        static let toView: CGAffineTransform = {
            let drawn = MascotArtwork.side * scale
            let inset = (CGSize(width: 22, height: 18).width - drawn) / 2
            let top = (18 - drawn) / 2 + drawn
            return CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: inset, ty: top)
        }()

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

    /// Where the pointer is, from −1 (far to the left of the mascot) to +1.
    /// The ear nearest it folds away: an ear is the one part of a hare that
    /// points at what has its attention.
    private var lean: CGFloat = 0
    private var pointerTimer: Timer?
    /// True while a loop owns the body — the wait's spread ears, or the idle
    /// flick — so the pointer does not fight it for the same layer.
    private var bodyIsLooping = false

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
    isolated deinit { blinkTimer?.invalidate() }

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
            // Eye ink applied per-state
            if self.eyesOpen {
                self.leftEyeLayer.fillColor  = self.ink
                self.rightEyeLayer.fillColor = self.ink
            } else {
                self.leftEyeLayer.strokeColor  = self.ink
                self.rightEyeLayer.strokeColor = self.ink
            }
        }
    }

    // MARK: - Pointer

    /// Follows the pointer while the hare is awake, and lets go when it sleeps.
    ///
    /// Polled rather than monitored: a global event monitor wakes this process
    /// for every mouse move on the machine, and what is wanted here is a lean
    /// that settles — fifteen times a second is finer than an ear can be seen
    /// to move.
    private func followPointer(_ follow: Bool) {
        pointerTimer?.invalidate()
        pointerTimer = nil
        guard follow else { return }
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in self?.readPointer() }
        }
    }

    private func readPointer() {
        guard !bodyIsLooping, let window else { return }
        let centre = window.convertPoint(toScreen: convert(CGPoint(x: bounds.midX,
                                                                   y: bounds.midY), to: nil))
        // Fully leant a third of a screen away; nearer than that it is partial,
        // which is what makes it read as following rather than as snapping.
        let reach = (window.screen ?? NSScreen.main)?.frame.width ?? 1440
        let wanted = max(-1, min(1, (NSEvent.mouseLocation.x - centre.x) / (reach / 3)))
        guard abs(wanted - lean) > 0.02 else { return }
        lean = wanted
        animPath(bodyLayer, to: Self.leaning(wanted), dur: 0.12)
    }

    // MARK: - Public

    func setState(_ state: MascotState) {
        bumpGen()
        blinkTimer?.invalidate()
        blinkTimer = nil

        switch state {
        case .sleeping:
            followPointer(false)
            bodyIsLooping = false
            bodyLayer.removeAnimation(forKey: "loop")
            lean = 0
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
            bodyIsLooping = false
            bodyLayer.removeAnimation(forKey: "loop")
            followPointer(true)

        case .waiting:
            let dir: EyeDirection = lastArcIsLeft ? .leftCenter : .rightCenter
            if !eyesOpen { applyOpenEyes(dir: dir, popAnim: true) }
            scheduleNextBlink()
            followPointer(false)
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

    /// The wait: ears spread, held, and let go again — over and over, slowly.
    /// The same two poses the pointer uses would be a twitch; this is a breath.
    private func spreadEars() {
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
        bodyLayer.add(loop, forKey: "loop")
    }

    // MARK: - Drawing helpers

    /// Show sleep arcs on both eyes. Resets all transforms.
    private func applyArcs(leftSeries: Bool) {
        eyesOpen = false
        lastArcIsLeft = leftSeries
        setBodyShape(for: nil, duration: 0.15)
        let (lc, rc) = eyeConfig(leftSeries ? .leftCenter : .rightCenter)
        let lArc = closedEyePath(center: lc)
        let rArc = closedEyePath(center: rc)

        noAnim {
            // Reset any scale transform left over from squeeze / pop
            self.leftEyeLayer.transform  = CATransform3DIdentity
            self.rightEyeLayer.transform = CATransform3DIdentity

            self.leftEyeLayer.path        = lArc
            self.leftEyeLayer.lineWidth   = 0.8 * G.scale
            self.leftEyeLayer.fillColor   = .clear
            self.leftEyeLayer.strokeColor = self.ink

            self.rightEyeLayer.path        = rArc
            self.rightEyeLayer.lineWidth   = 0.8 * G.scale
            self.rightEyeLayer.fillColor   = .clear
            self.rightEyeLayer.strokeColor = self.ink
        }
    }

    /// Set open-eye glint-carved paths, optionally animating a spring pop.
    private func applyOpenEyes(dir: EyeDirection, popAnim: Bool) {
        eyesOpen = true
        lastOpenDirection = dir
        setBodyShape(for: dir, duration: 0.15)
        let (lc, rc) = eyeConfig(dir)

        noAnim {
            self.leftEyeLayer.transform  = CATransform3DIdentity
            self.rightEyeLayer.transform = CATransform3DIdentity

            self.leftEyeLayer.path  = self.eyePath(center: lc)
            self.rightEyeLayer.path = self.eyePath(center: rc)

            self.leftEyeLayer.lineWidth   = 0.8 * G.scale
            self.leftEyeLayer.fillColor   = self.ink
            self.leftEyeLayer.strokeColor = .clear
            self.rightEyeLayer.lineWidth  = 0.8 * G.scale
            self.rightEyeLayer.fillColor  = self.ink
            self.rightEyeLayer.strokeColor = .clear

            if popAnim {
                // Start at scale=0; the spring animation below will pop to 1
                self.leftEyeLayer.transform  = CATransform3DMakeScale(0, 0, 1)
                self.rightEyeLayer.transform = CATransform3DMakeScale(0, 0, 1)
            }
        }

        if popAnim {
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0
            spring.toValue   = 1
            spring.stiffness = 280
            spring.damping   = 18
            spring.duration  = spring.settlingDuration
            leftEyeLayer.add(spring,  forKey: "pop")
            rightEyeLayer.add(spring, forKey: "pop")
            // Restore model so when animation ends it reveals scale=1
            noAnim {
                self.leftEyeLayer.transform  = CATransform3DIdentity
                self.rightEyeLayer.transform = CATransform3DIdentity
            }
        }
    }

    /// Apply wink: one eye closes to a sleep arc, the other stays open.
    /// leftWinks=true  → right-series in play, left eye squints
    /// leftWinks=false → left-series in play, right eye squints
    private func applyWink(leftWinks: Bool) {
        noAnim {
            if leftWinks {
                // Left eye → arc (right-series left-eye arc)
                self.leftEyeLayer.path        = self.closedEyePath(
                    center: self.eyeConfig(.rightCenter).lEye)
                self.leftEyeLayer.lineWidth   = 0.8 * G.scale
                self.leftEyeLayer.fillColor   = .clear
                self.leftEyeLayer.strokeColor = self.ink
                // Right stays open
                let rc = eyeConfig(.rightCenter).rEye
                self.rightEyeLayer.path        = self.eyePath(center: rc)
                self.rightEyeLayer.lineWidth   = 0.8 * G.scale
                self.rightEyeLayer.fillColor   = self.ink
                self.rightEyeLayer.strokeColor = .clear
            } else {
                // Right eye → arc (left-series right-eye arc)
                self.rightEyeLayer.path        = self.closedEyePath(
                    center: self.eyeConfig(.leftCenter).rEye)
                self.rightEyeLayer.lineWidth   = 0.8 * G.scale
                self.rightEyeLayer.fillColor   = .clear
                self.rightEyeLayer.strokeColor = self.ink
                // Left stays open
                let lc = eyeConfig(.leftCenter).lEye
                self.leftEyeLayer.path        = self.eyePath(center: lc)
                self.leftEyeLayer.lineWidth   = 0.8 * G.scale
                self.leftEyeLayer.fillColor   = self.ink
                self.leftEyeLayer.strokeColor = .clear
            }
        }
    }

    // MARK: - Eye movement

    private func animateMoveEyes(to dir: EyeDirection, duration: CFTimeInterval) {
        lastOpenDirection = dir
        setBodyShape(for: dir, duration: duration)
        let (lc, rc) = eyeConfig(dir)

        animPath(leftEyeLayer,  to: eyePath(center: lc), dur: duration)
        animPath(rightEyeLayer, to: eyePath(center: rc), dur: duration)
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
    private func animateSqueeze(completion: @escaping @MainActor () -> Void) {
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

    private func animPath(_ layer: CAShapeLayer, to path: CGPath, dur: CFTimeInterval) {
        let from = layer.presentation()?.path ?? layer.path
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

    /// Open-eye outline at an absolute center point.
    ///
    /// The eye is a single filled shape with the highlight *carved out* of the
    /// fill (negative space, per Figma) — not a light pupil drawn on top.
    /// Figma's static states mirror the glint per gaze direction, but in
    /// motion that reads as the eyes flip-flopping. Instead one constant shape
    /// translates with the gaze, so the glint moves like a pupil — gaze
    /// changes are pure movement, never a flip.
    private func eyePath(center: CGPoint) -> CGPath {
        // The artwork's own eye: two points across, with a small bite taken out
        // of its side for the glint. The eye this replaces was three by four,
        // drawn for a body twice this size — squeezed down to two points its
        // glint ate the pupil and what was left read as the letter C.
        let half = G.eyeW / 2
        let place = CGAffineTransform(translationX: center.x - half, y: center.y - half)
        let p = CGMutablePath()
        p.addPath(Self.openEye.cgPath, transform: place.concatenating(G.toView))
        return p
    }

    /// Parsed once: the eye is the same drawing wherever it is put.
    private static let openEye: VectorPath = {
        VectorPath.parse(MascotArtwork.Eye.open.replacingOccurrences(of: "\n", with: ""))
            ?? VectorPath(segments: [])
    }()

    /// The closed eye — the little arc the artwork draws for sleep — at a
    /// centre given in artwork units.
    private func closedEyePath(center: CGPoint) -> CGPath {
        let half = G.closedEyeWidth / 2
        let p = CGMutablePath()
        let t = CGAffineTransform(translationX: center.x - half, y: center.y - 0.15)
            .concatenating(G.toView)
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
