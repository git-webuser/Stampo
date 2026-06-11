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
    case colorPicking(EyeDirection)
    case celebrating
    case countdown
}

// MARK: - MascotStatusView

/// Menu-bar mascot. View size: 20 × 16 pt (y = 0 at bottom, CALayer convention).
final class MascotStatusView: NSView {

    // MARK: Layers

    private let bodyLayer        = CAShapeLayer()
    private let leftEyeLayer     = CAShapeLayer()
    private let rightEyeLayer    = CAShapeLayer()

    // MARK: Geometry (all in CALayer coords: y from bottom, view 20×16)

    private enum G {
        // Eye box: 3 × 4 pt (Figma component, exact glint-carved paths below)
        static let eyeW: CGFloat = 3
        static let eyeH: CGFloat = 4

        // Eye X positions: left-series and right-series
        static let lEyeX: (CGFloat, CGFloat) = (5, 12)   // left-eye, right-eye when gaze=left
        static let rEyeX: (CGFloat, CGFloat) = (8, 15)   // gaze=right

        // Eye Y centers (y from bottom). Figma: looking up raises the eyes
        // (inset-top 3 → CALayer y 11), looking down lowers them (inset-top 5 → y 9).
        static let eyeYup: CGFloat = 11
        static let eyeYmd: CGFloat = 10
        static let eyeYdn: CGFloat = 9

        // Sleep arcs: quadratic bezier, same Y geometry as before, X positions
        // updated per Figma (shifted ~0.25 pt inward on each side).
        // arcY = base (endpoints), arcTop = control-point peak.
        static let arcY:   CGFloat = 9.75
        static let arcTop: CGFloat = 10.25

        struct Arc {
            let s, c, e: CGPoint
            var path: CGPath {
                let p = CGMutablePath()
                p.move(to: s)
                p.addQuadCurve(to: e, control: c)
                return p
            }
        }

        // Left-series arcs (eyes at x = 5, 12)
        static let lsL = Arc(s: .init(x: 3.75,  y: arcY), c: .init(x: 5.25,  y: arcTop), e: .init(x: 6.75,  y: arcY))
        static let lsR = Arc(s: .init(x: 10.25, y: arcY), c: .init(x: 11.75, y: arcTop), e: .init(x: 13.25, y: arcY))
        // Right-series arcs (eyes at x = 8, 15; x values shifted +3 from left-series)
        static let rsL = Arc(s: .init(x: 6.75,  y: arcY), c: .init(x: 8.25,  y: arcTop), e: .init(x: 9.75,  y: arcY))
        static let rsR = Arc(s: .init(x: 13.25, y: arcY), c: .init(x: 14.75, y: arcTop), e: .init(x: 16.25, y: arcY))
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

    // MARK: Init

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }
    deinit { blinkTimer?.invalidate() }

    // MARK: Setup

    private func setup() {
        wantsLayer = true

        // Body — exact Figma outlines: rectangle-ish squircle at rest, organic
        // trapezoid variants when the mascot looks up/down (perspective metaphor).
        // All three paths share the same segment structure, so CoreAnimation
        // morphs between them cleanly.
        bodyLayer.path      = MascotStatusView.bodyPathCenter
        bodyLayer.fillColor = .clear
        bodyLayer.lineWidth = 2
        layer!.addSublayer(bodyLayer)

        // Eye layers
        for eye in [leftEyeLayer, rightEyeLayer] {
            eye.lineWidth  = 1.75
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

    // MARK: - Public

    func setState(_ state: MascotState) {
        bumpGen()
        blinkTimer?.invalidate()
        blinkTimer = nil

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
                self?.animateBlink()
            }
        }
    }

    // MARK: - Drawing helpers

    /// Show sleep arcs on both eyes. Resets all transforms.
    private func applyArcs(leftSeries: Bool) {
        eyesOpen = false
        lastArcIsLeft = leftSeries
        setBodyShape(for: nil, duration: 0.15)
        let lArc = leftSeries ? G.lsL : G.rsL
        let rArc = leftSeries ? G.lsR : G.rsR

        noAnim {
            // Reset any scale transform left over from squeeze / pop
            self.leftEyeLayer.transform  = CATransform3DIdentity
            self.rightEyeLayer.transform = CATransform3DIdentity

            self.leftEyeLayer.path        = lArc.path
            self.leftEyeLayer.lineWidth   = 1.75
            self.leftEyeLayer.fillColor   = .clear
            self.leftEyeLayer.strokeColor = self.ink

            self.rightEyeLayer.path        = rArc.path
            self.rightEyeLayer.lineWidth   = 1.75
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

            self.leftEyeLayer.lineWidth   = 1.75
            self.leftEyeLayer.fillColor   = self.ink
            self.leftEyeLayer.strokeColor = .clear
            self.rightEyeLayer.lineWidth  = 1.75
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
                self.leftEyeLayer.path        = G.rsL.path
                self.leftEyeLayer.lineWidth   = 1.75
                self.leftEyeLayer.fillColor   = .clear
                self.leftEyeLayer.strokeColor = self.ink
                // Right stays open
                let dir = EyeDirection.rightCenter
                let rc = CGPoint(x: G.rEyeX.1, y: G.eyeYmd)
                self.rightEyeLayer.path        = self.eyePath(center: rc)
                self.rightEyeLayer.lineWidth   = 1.75
                self.rightEyeLayer.fillColor   = self.ink
                self.rightEyeLayer.strokeColor = .clear
            } else {
                // Right eye → arc (left-series right-eye arc)
                self.rightEyeLayer.path        = G.lsR.path
                self.rightEyeLayer.lineWidth   = 1.75
                self.rightEyeLayer.fillColor   = .clear
                self.rightEyeLayer.strokeColor = self.ink
                // Left stays open
                let dir = EyeDirection.leftCenter
                let lc = CGPoint(x: G.lEyeX.0, y: G.eyeYmd)
                self.leftEyeLayer.path        = self.eyePath(center: lc)
                self.leftEyeLayer.lineWidth   = 1.75
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
            guard let self, self.eyesOpen else { return }
            self.animateBlink()
            self.scheduleNextBlink()
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
    private func animateSqueeze(completion: @escaping () -> Void) {
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13, execute: completion)
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

    /// Vertical gaze component of a direction.
    private enum VGaze { case up, center, down }

    private func vGaze(_ dir: EyeDirection) -> VGaze {
        switch dir {
        case .leftUp,     .rightUp:     return .up
        case .leftCenter, .rightCenter: return .center
        case .leftDown,   .rightDown:   return .down
        }
    }

    /// Open-eye outline at an absolute center point.
    ///
    /// The eye is a single filled shape with the highlight *carved out* of the
    /// fill (negative space, per Figma) — not a light pupil drawn on top.
    /// Figma's static states mirror the glint per gaze direction, but in
    /// motion that reads as the eyes flip-flopping. Instead one constant shape
    /// translates with the gaze, so the glint moves like a pupil — gaze
    /// changes are pure movement, never a flip.
    private func eyePath(center: CGPoint) -> CGPath {
        // Maps the Figma 3×4 box (y down) onto CALayer coords around `center`.
        let t = CGAffineTransform(
            a: 1, b: 0,
            c: 0, d: -1,
            tx: center.x - G.eyeW / 2,
            ty: center.y + G.eyeH / 2
        )

        let p = CGMutablePath()
        Self.addEyeOutlineCenter(to: p, t: t)
        return p
    }

    /// Eye outline from Figma flatten (glint carved mid-right, vertically
    /// symmetric). SVG path "Eye" of node 965:222, viewBox 0 0 3 4.
    private static func addEyeOutlineCenter(to p: CGMutablePath, t: CGAffineTransform) {
        p.move(to: .init(x: 1.50098, y: 0), transform: t)
        p.addCurve(to: .init(x: 2.89642, y: 0.95195), control1: .init(x: 2.13572, y: 0.0002),  control2: .init(x: 2.67772, y: 0.39478), transform: t)
        p.addCurve(to: .init(x: 2.93115, y: 1.10133), control1: .init(x: 2.92421, y: 1.02275), control2: .init(x: 2.9381, y: 1.05814), transform: t)
        p.addCurve(to: .init(x: 2.87619, y: 1.19832), control1: .init(x: 2.92567, y: 1.13536), control2: .init(x: 2.90257, y: 1.17613), transform: t)
        p.addCurve(to: .init(x: 2.7102, y: 1.24864),  control1: .init(x: 2.84272, y: 1.22648), control2: .init(x: 2.79855, y: 1.23387), transform: t)
        p.addLine(to: .init(x: 2.39258, y: 1.30176), transform: t)
        p.addCurve(to: .init(x: 2.0791, y: 1.375),    control1: .init(x: 2.22808, y: 1.32917), control2: .init(x: 2.14523, y: 1.34241), transform: t)
        p.addCurve(to: .init(x: 1.82227, y: 1.67969), control1: .init(x: 1.9549, y: 1.43632),  control2: .init(x: 1.86224, y: 1.54706), transform: t)
        p.addCurve(to: .init(x: 1.80078, y: 2),       control1: .init(x: 1.80108, y: 1.7502),  control2: .init(x: 1.80078, y: 1.83347), transform: t)
        p.addCurve(to: .init(x: 1.82227, y: 2.32031), control1: .init(x: 1.80078, y: 2.16657), control2: .init(x: 1.80106, y: 2.24978), transform: t)
        p.addCurve(to: .init(x: 2.0791, y: 2.625),    control1: .init(x: 1.86225, y: 2.45295), control2: .init(x: 1.95488, y: 2.56369), transform: t)
        p.addCurve(to: .init(x: 2.39258, y: 2.69824), control1: .init(x: 2.14523, y: 2.65759), control2: .init(x: 2.22808, y: 2.67083), transform: t)
        p.addLine(to: .init(x: 2.70987, y: 2.75077), transform: t)
        p.addCurve(to: .init(x: 2.87607, y: 2.80086), control1: .init(x: 2.79831, y: 2.76541), control2: .init(x: 2.84253, y: 2.77273), transform: t)
        p.addCurve(to: .init(x: 2.93116, y: 2.89785), control1: .init(x: 2.90249, y: 2.82304), control2: .init(x: 2.92565, y: 2.8638), transform: t)
        p.addCurve(to: .init(x: 2.8965, y: 3.04737),  control1: .init(x: 2.93816, y: 2.94106), control2: .init(x: 2.92427, y: 2.9765), transform: t)
        p.addCurve(to: .init(x: 1.50098, y: 4),       control1: .init(x: 2.678, y: 3.60489),   control2: .init(x: 2.13597, y: 3.9998), transform: t)
        p.addCurve(to: .init(x: 0.00098, y: 2.5),     control1: .init(x: 0.67255, y: 4),       control2: .init(x: 0.00098, y: 3.32843), transform: t)
        p.addLine(to: .init(x: 0.00098, y: 1.5), transform: t)
        p.addCurve(to: .init(x: 1.50098, y: 0),       control1: .init(x: 0.00098, y: 0.67157), control2: .init(x: 0.67255, y: 0), transform: t)
        p.closeSubpath()
    }

    // MARK: - Eye config

    private func eyeConfig(_ dir: EyeDirection) -> (lEye: CGPoint, rEye: CGPoint) {
        let lx: CGFloat
        let rx: CGFloat
        let ey: CGFloat

        switch dir {
        case .leftCenter:  lx = G.lEyeX.0; rx = G.lEyeX.1; ey = G.eyeYmd
        case .leftUp:      lx = G.lEyeX.0; rx = G.lEyeX.1; ey = G.eyeYup
        case .leftDown:    lx = G.lEyeX.0; rx = G.lEyeX.1; ey = G.eyeYdn
        case .rightCenter: lx = G.rEyeX.0; rx = G.rEyeX.1; ey = G.eyeYmd
        case .rightUp:     lx = G.rEyeX.0; rx = G.rEyeX.1; ey = G.eyeYup
        case .rightDown:   lx = G.rEyeX.0; rx = G.rEyeX.1; ey = G.eyeYdn
        }

        return (CGPoint(x: lx, y: ey), CGPoint(x: rx, y: ey))
    }

    // MARK: - Sequence helpers

    @discardableResult
    private func bumpGen() -> Int {
        sequenceGen &+= 1
        return sequenceGen
    }

    private func after(_ delay: TimeInterval, gen: Int, action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
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

    // MARK: - Body paths (exact Figma geometry)

    /// Morph the body outline to match a gaze direction (nil = resting/sleep).
    /// All three outlines share an identical segment structure
    /// (move + line + 12 cubics + line), so CoreAnimation interpolates cleanly.
    private func setBodyShape(for dir: EyeDirection?, duration: CFTimeInterval) {
        let target: CGPath
        switch dir.map(vGaze) {
        case .up:           target = Self.bodyPathUp
        case .down:         target = Self.bodyPathDown
        case .center, nil:  target = Self.bodyPathCenter
        }
        if duration <= 0 {
            noAnim { self.bodyLayer.path = target }
        } else {
            animPath(bodyLayer, to: target, dur: duration)
        }
    }

    /// Resting body — symmetric squircle (Figma node 965:230, viewBox 20×16,
    /// y flipped to CALayer coords; path pre-inset 1 pt for the centred 2 pt
    /// stroke). Unlike the older traced asset, there are no baked-in slants.
    private static let bodyPathCenter: CGPath = {
        let p = CGMutablePath()
        p.move(to:    .init(x:  8.000, y: 15.000))
        p.addLine(to: .init(x: 12.000, y: 15.000))
        p.addCurve(to: .init(x: 15.294, y: 14.830), control1: .init(x: 13.924, y: 15.000), control2: .init(x: 14.690, y: 14.992))
        p.addCurve(to: .init(x: 18.830, y: 11.294), control1: .init(x: 17.019, y: 14.368), control2: .init(x: 18.368, y: 13.019))
        p.addCurve(to: .init(x: 19.000, y:  8.000), control1: .init(x: 18.992, y: 10.690), control2: .init(x: 19.000, y:  9.924))
        p.addCurve(to: .init(x: 18.830, y:  4.706), control1: .init(x: 19.000, y:  6.076), control2: .init(x: 18.992, y:  5.310))
        p.addCurve(to: .init(x: 15.294, y:  1.170), control1: .init(x: 18.368, y:  2.981), control2: .init(x: 17.019, y:  1.632))
        p.addCurve(to: .init(x: 12.000, y:  1.000), control1: .init(x: 14.690, y:  1.008), control2: .init(x: 13.924, y:  1.000))
        p.addLine(to: .init(x:  8.000, y:  1.000))
        p.addCurve(to: .init(x:  4.706, y:  1.170), control1: .init(x:  6.076, y:  1.000), control2: .init(x:  5.310, y:  1.008))
        p.addCurve(to: .init(x:  1.170, y:  4.706), control1: .init(x:  2.981, y:  1.632), control2: .init(x:  1.632, y:  2.981))
        p.addCurve(to: .init(x:  1.000, y:  8.000), control1: .init(x:  1.008, y:  5.310), control2: .init(x:  1.000, y:  6.076))
        p.addCurve(to: .init(x:  1.170, y: 11.294), control1: .init(x:  1.000, y:  9.924), control2: .init(x:  1.008, y: 10.690))
        p.addCurve(to: .init(x:  4.706, y: 14.830), control1: .init(x:  1.632, y: 13.019), control2: .init(x:  2.981, y: 14.368))
        p.addCurve(to: .init(x:  8.000, y: 15.000), control1: .init(x:  5.310, y: 14.992), control2: .init(x:  6.076, y: 15.000))
        p.addLine(to: .init(x:  8.000, y: 15.000))
        p.closeSubpath()
        return p
    }()

    /// Looking-up body — top edge recedes, organic perspective trapezoid
    /// (Figma node 965:182, x offset +0.212, y flipped to CALayer coords).
    private static let bodyPathUp: CGPath = {
        let p = CGMutablePath()
        p.move(to:    .init(x:  8.254, y: 15.000))
        p.addLine(to: .init(x: 11.485, y: 15.000))
        p.addCurve(to: .init(x: 14.607, y: 14.843), control1: .init(x: 13.303, y: 15.000), control2: .init(x: 14.026, y: 14.992))
        p.addCurve(to: .init(x: 18.119, y: 11.543), control1: .init(x: 16.265, y: 14.417), control2: .init(x: 17.590, y: 13.171))
        p.addCurve(to: .init(x: 18.470, y:  8.437), control1: .init(x: 18.304, y: 10.972), control2: .init(x: 18.357, y: 10.251))
        p.addCurve(to: .init(x: 18.503, y:  4.959), control1: .init(x: 18.597, y:  6.405), control2: .init(x: 18.639, y:  5.595))
        p.addCurve(to: .init(x: 14.957, y:  1.185), control1: .init(x: 18.116, y:  3.139), control2: .init(x: 16.750, y:  1.685))
        p.addCurve(to: .init(x: 11.485, y:  1.000), control1: .init(x: 14.331, y:  1.010), control2: .init(x: 13.520, y:  1.000))
        p.addLine(to: .init(x:  8.254, y:  1.000))
        p.addCurve(to: .init(x:  4.871, y:  1.177), control1: .init(x:  6.274, y:  1.000), control2: .init(x:  5.486, y:  1.009))
        p.addCurve(to: .init(x:  1.329, y:  4.832), control1: .init(x:  3.112, y:  1.658), control2: .init(x:  1.755, y:  3.059))
        p.addCurve(to: .init(x:  1.257, y:  8.219), control1: .init(x:  1.180, y:  5.452), control2: .init(x:  1.195, y:  6.240))
        p.addCurve(to: .init(x:  1.521, y: 11.419), control1: .init(x:  1.315, y: 10.088), control2: .init(x:  1.347, y: 10.832))
        p.addCurve(to: .init(x:  5.047, y: 14.836), control1: .init(x:  2.018, y: 13.096), control2: .init(x:  3.355, y: 14.392))
        p.addCurve(to: .init(x:  8.254, y: 15.000), control1: .init(x:  5.639, y: 14.991), control2: .init(x:  6.383, y: 15.000))
        p.addLine(to: .init(x:  8.254, y: 15.000))
        p.closeSubpath()
        return p
    }()

    /// Looking-down body — bottom edge recedes; exact vertical mirror of the
    /// looking-up outline (Figma node 965:278).
    private static let bodyPathDown: CGPath = {
        let p = CGMutablePath()
        p.move(to:    .init(x:  8.254, y: 15.000))
        p.addLine(to: .init(x: 11.485, y: 15.000))
        p.addCurve(to: .init(x: 14.957, y: 14.815), control1: .init(x: 13.520, y: 15.000), control2: .init(x: 14.331, y: 14.990))
        p.addCurve(to: .init(x: 18.503, y: 11.041), control1: .init(x: 16.750, y: 14.315), control2: .init(x: 18.116, y: 12.861))
        p.addCurve(to: .init(x: 18.470, y:  7.563), control1: .init(x: 18.639, y: 10.405), control2: .init(x: 18.597, y:  9.595))
        p.addCurve(to: .init(x: 18.119, y:  4.457), control1: .init(x: 18.357, y:  5.749), control2: .init(x: 18.304, y:  5.028))
        p.addCurve(to: .init(x: 14.607, y:  1.157), control1: .init(x: 17.590, y:  2.829), control2: .init(x: 16.265, y:  1.583))
        p.addCurve(to: .init(x: 11.485, y:  1.000), control1: .init(x: 14.026, y:  1.008), control2: .init(x: 13.303, y:  1.000))
        p.addLine(to: .init(x:  8.254, y:  1.000))
        p.addCurve(to: .init(x:  5.047, y:  1.164), control1: .init(x:  6.383, y:  1.000), control2: .init(x:  5.639, y:  1.009))
        p.addCurve(to: .init(x:  1.521, y:  4.581), control1: .init(x:  3.355, y:  1.608), control2: .init(x:  2.018, y:  2.904))
        p.addCurve(to: .init(x:  1.257, y:  7.781), control1: .init(x:  1.347, y:  5.168), control2: .init(x:  1.315, y:  5.912))
        p.addCurve(to: .init(x:  1.329, y: 11.168), control1: .init(x:  1.195, y:  9.760), control2: .init(x:  1.180, y: 10.548))
        p.addCurve(to: .init(x:  4.871, y: 14.823), control1: .init(x:  1.755, y: 12.941), control2: .init(x:  3.112, y: 14.342))
        p.addCurve(to: .init(x:  6.976, y: 14.996), control1: .init(x:  5.332, y: 14.949), control2: .init(x:  5.891, y: 14.986))
        p.addLine(to: .init(x:  8.254, y: 15.000))
        p.closeSubpath()
        return p
    }()
}
