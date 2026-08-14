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

/// Menu-bar mascot. View size: 22 × 18 pt (y = 0 at bottom, CALayer convention).
/// Body outlines come straight from the Figma 22.18×18 export.
final class MascotStatusView: NSView {

    // MARK: Layers

    private let bodyLayer        = CAShapeLayer()
    private let leftEyeLayer     = CAShapeLayer()
    private let rightEyeLayer    = CAShapeLayer()

    // MARK: Geometry (all in CALayer coords: y from bottom, view 22×18)

    private enum G {
        // Eye box: 3 × 4 pt (Figma component, exact glint-carved paths below)
        static let eyeW: CGFloat = 3
        static let eyeH: CGFloat = 4

        // Eye X positions: left-series and right-series (gaze drives position),
        // shifted +1 to recenter inside the larger 22×18 body. Gap kept at 7 pt;
        // the wider Figma spacing read too far apart at menu-bar size.
        static let lEyeX: (CGFloat, CGFloat) = (6, 13)   // left-eye, right-eye when gaze=left
        static let rEyeX: (CGFloat, CGFloat) = (9, 16)   // gaze=right

        // Eye Y centers (y from bottom). Looking up raises the eyes,
        // looking down lowers them.
        static let eyeYup: CGFloat = 12
        static let eyeYmd: CGFloat = 11
        static let eyeYdn: CGFloat = 10

        // Sleep arcs: quadratic bezier. Shifted +1/+1 with the eyes.
        static let arcY:   CGFloat = 10.75
        static let arcTop: CGFloat = 11.25

        struct Arc {
            let s, c, e: CGPoint
            var path: CGPath {
                let p = CGMutablePath()
                p.move(to: s)
                p.addQuadCurve(to: e, control: c)
                return p
            }
        }

        // Left-series arcs (eyes at x = 6, 13)
        static let lsL = Arc(s: .init(x: 4.75,  y: arcY), c: .init(x: 6.25,  y: arcTop), e: .init(x: 7.75,  y: arcY))
        static let lsR = Arc(s: .init(x: 11.25, y: arcY), c: .init(x: 12.75, y: arcTop), e: .init(x: 14.25, y: arcY))
        // Right-series arcs (eyes at x = 9, 16; x values shifted +3 from left-series)
        static let rsL = Arc(s: .init(x: 7.75,  y: arcY), c: .init(x: 9.25,  y: arcTop), e: .init(x: 10.75, y: arcY))
        static let rsR = Arc(s: .init(x: 14.25, y: arcY), c: .init(x: 15.75, y: arcTop), e: .init(x: 17.25, y: arcY))
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
    isolated deinit { blinkTimer?.invalidate() }

    // MARK: Setup

    private func setup() {
        wantsLayer = true

        // Body — exact Figma outlines: rectangle-ish squircle at rest, organic
        // trapezoid variants when the mascot looks up/down (perspective metaphor).
        // All three paths share the same segment structure, so CoreAnimation
        // morphs between them cleanly.
        bodyLayer.path      = MascotStatusView.bodyCenter
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
                Task { @MainActor [weak self] in
                    self?.animateBlink()
                }
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
                let rc = eyeConfig(.rightCenter).rEye
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
                let lc = eyeConfig(.leftCenter).lEye
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

    /// Eye-box centers per gaze. Glint shape is constant across states — only
    /// the eye position tracks the gaze (left/right series + up/center/down).
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
        let target: CGPath
        switch dir {
        case .leftUp:                        target = Self.bodyUpLeft
        case .rightUp:                       target = Self.bodyUpRight
        case .leftDown:                      target = Self.bodyDownLeft
        case .rightDown:                     target = Self.bodyDownRight
        case .leftCenter, .rightCenter, nil: target = Self.bodyCenter
        }
        if duration <= 0 {
            noAnim { self.bodyLayer.path = target }
        } else {
            animPath(bodyLayer, to: target, dur: duration)
        }
    }

    /// Figma exports body coords y-down in an 18-tall box; flip to CALayer y-up.
    private static func flippedBody(_ build: (CGMutablePath) -> Void) -> CGPath {
        let raw = CGMutablePath()
        build(raw)
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 18)
        return raw.copy(using: &flip) ?? raw
    }

    /// Resting / centered body — perfectly symmetric squircle (Figma node 1087:307,
    /// updated). Edges at x=1 / x=21, centered at 11; clean 1 pt margin each side.
    private static let bodyCenter: CGPath = flippedBody { p in
        p.move(to:    .init(x: 13.00000, y:  1.00004))
        p.addLine(to: .init(x:  9.00004, y:  1.00004))
        p.addCurve(to: .init(x:  5.44712, y:  1.20448), control1: .init(x:  7.14009, y:  1.00004), control2: .init(x:  6.21012, y:  1.00004))
        p.addCurve(to: .init(x:  1.20448, y:  5.44712), control1: .init(x:  3.37657, y:  1.75928), control2: .init(x:  1.75928, y:  3.37657))
        p.addCurve(to: .init(x:  1.00004, y:  9.00004), control1: .init(x:  1.00004, y:  6.21012), control2: .init(x:  1.00004, y:  7.14009))
        p.addCurve(to: .init(x:  1.20448, y: 12.553),   control1: .init(x:  1.00004, y: 10.86),    control2: .init(x:  1.00004, y: 11.79))
        p.addCurve(to: .init(x:  5.44712, y: 16.7956),  control1: .init(x:  1.75928, y: 14.6235),  control2: .init(x:  3.37657, y: 16.2408))
        p.addCurve(to: .init(x:  9.00004, y: 17),       control1: .init(x:  6.21012, y: 17),       control2: .init(x:  7.14009, y: 17))
        p.addLine(to: .init(x: 13.00000, y: 17))
        p.addCurve(to: .init(x: 16.553,  y: 16.7956),  control1: .init(x: 14.86,    y: 17),       control2: .init(x: 15.79,    y: 17))
        p.addCurve(to: .init(x: 20.7956, y: 12.553),   control1: .init(x: 18.6235,  y: 16.2408),  control2: .init(x: 20.2408,  y: 14.6235))
        p.addCurve(to: .init(x: 21.00000, y:  9.00004), control1: .init(x: 21,       y: 11.79),    control2: .init(x: 21,       y: 10.86))
        p.addCurve(to: .init(x: 20.7956, y:  5.44712), control1: .init(x: 21,       y:  7.14009), control2: .init(x: 21,       y:  6.21012))
        p.addCurve(to: .init(x: 16.553,  y:  1.20448), control1: .init(x: 20.2408,  y:  3.37657), control2: .init(x: 18.6235,  y:  1.75928))
        p.addCurve(to: .init(x: 13.00000, y:  1.00004), control1: .init(x: 15.79,    y:  1.00004), control2: .init(x: 14.86,    y:  1.00004))
        p.closeSubpath()
    }

    /// Gaze up-left — lower-left corner pulls toward the viewer (Figma 1087:296).
    private static let bodyUpLeft: CGPath = flippedBody { p in
        p.move(to:    .init(x: 13.1815, y:  1.00004))
        p.addLine(to: .init(x:  9.24373, y:  1.00004))
        p.addCurve(to: .init(x:  6.04569, y:  1.17354), control1: .init(x:  7.58219, y:  1.00004), control2: .init(x:  6.75142, y:  1.00004))
        p.addCurve(to: .init(x:  1.87434, y:  4.85594), control1: .init(x:  4.13573, y:  1.64312), control2: .init(x:  2.57719, y:  3.01897))
        p.addCurve(to: .init(x:  1.30551, y:  8.00776), control1: .init(x:  1.61464, y:  5.5347),  control2: .init(x:  1.5116,  y:  6.35905))
        p.addCurve(to: .init(x:  1.05306, y: 11.9451),  control1: .init(x:  1.04761, y: 10.0709),  control2: .init(x:  0.918664, y: 11.1025))
        p.addCurve(to: .init(x:  5.30548, y: 16.7622),  control1: .init(x:  1.41885, y: 14.2384),  control2: .init(x:  3.07522, y: 16.1147))
        p.addCurve(to: .init(x:  9.24373, y: 17),       control1: .init(x:  6.12491, y: 17),       control2: .init(x:  7.16451, y: 17))
        p.addLine(to: .init(x: 13.1815, y: 17))
        p.addCurve(to: .init(x: 16.7344, y: 16.7956),  control1: .init(x: 15.0414, y: 17),       control2: .init(x: 15.9714, y: 17))
        p.addCurve(to: .init(x: 20.977,  y: 12.553),   control1: .init(x: 18.8049, y: 16.2408),  control2: .init(x: 20.4222, y: 14.6235))
        p.addCurve(to: .init(x: 21.1815, y:  9.00004), control1: .init(x: 21.1815, y: 11.79),    control2: .init(x: 21.1815, y: 10.86))
        p.addCurve(to: .init(x: 20.977,  y:  5.44712), control1: .init(x: 21.1815, y:  7.14009), control2: .init(x: 21.1815, y:  6.21012))
        p.addCurve(to: .init(x: 16.7344, y:  1.20448), control1: .init(x: 20.4222, y:  3.37657), control2: .init(x: 18.8049, y:  1.75928))
        p.addCurve(to: .init(x: 13.1815, y:  1.00004), control1: .init(x: 15.9714, y:  1.00004), control2: .init(x: 15.0414, y:  1.00004))
        p.closeSubpath()
    }

    /// Gaze up-right — lower-right corner pulls toward the viewer (Figma 1087:322).
    private static let bodyUpRight: CGPath = flippedBody { p in
        p.move(to:    .init(x: 12.9378, y:  1.00004))
        p.addLine(to: .init(x:  9.00004, y:  1.00004))
        p.addCurve(to: .init(x:  5.44712, y:  1.20448), control1: .init(x:  7.14009, y:  1.00004), control2: .init(x:  6.21012, y:  1.00004))
        p.addCurve(to: .init(x:  1.20448, y:  5.44712), control1: .init(x:  3.37657, y:  1.75928), control2: .init(x:  1.75928, y:  3.37657))
        p.addCurve(to: .init(x:  1.00004, y:  9.00004), control1: .init(x:  1.00004, y:  6.21012), control2: .init(x:  1.00004, y:  7.14009))
        p.addCurve(to: .init(x:  1.20448, y: 12.553),   control1: .init(x:  1.00004, y: 10.86),    control2: .init(x:  1.00004, y: 11.79))
        p.addCurve(to: .init(x:  5.44712, y: 16.7956),  control1: .init(x:  1.75928, y: 14.6235),  control2: .init(x:  3.37657, y: 16.2408))
        p.addCurve(to: .init(x:  9.00004, y: 17),       control1: .init(x:  6.21012, y: 17),       control2: .init(x:  7.14009, y: 17))
        p.addLine(to: .init(x: 12.9378, y: 17))
        p.addCurve(to: .init(x: 16.876,  y: 16.7622),  control1: .init(x: 15.017,  y: 17),       control2: .init(x: 16.0566, y: 17))
        p.addCurve(to: .init(x: 21.1284, y: 11.9451),  control1: .init(x: 19.1063, y: 16.1147),  control2: .init(x: 20.7627, y: 14.2384))
        p.addCurve(to: .init(x: 20.876,  y:  8.00778), control1: .init(x: 21.2628, y: 11.1025),  control2: .init(x: 21.1339, y: 10.0709))
        p.addCurve(to: .init(x: 20.3072, y:  4.85594), control1: .init(x: 20.6699, y:  6.35905), control2: .init(x: 20.5669, y:  5.5347))
        p.addCurve(to: .init(x: 16.1358, y:  1.17354), control1: .init(x: 19.6043, y:  3.01897), control2: .init(x: 18.0458, y:  1.64312))
        p.addCurve(to: .init(x: 12.9378, y:  1.00004), control1: .init(x: 15.4301, y:  1.00004), control2: .init(x: 14.5993, y:  1.00004))
        p.closeSubpath()
    }

    /// Gaze down-left — upper-left corner pulls toward the viewer (Figma 1087:311).
    private static let bodyDownLeft: CGPath = flippedBody { p in
        p.move(to:    .init(x: 13.1815, y:  1.00004))
        p.addLine(to: .init(x:  9.24373, y:  1.00004))
        p.addCurve(to: .init(x:  5.30548, y:  1.23792), control1: .init(x:  7.16451, y:  1.00004), control2: .init(x:  6.12491, y:  1.00004))
        p.addCurve(to: .init(x:  1.05306, y:  6.05498), control1: .init(x:  3.07522, y:  1.88534), control2: .init(x:  1.41885, y:  3.76164))
        p.addCurve(to: .init(x:  1.30551, y:  9.99232), control1: .init(x:  0.918664, y: 6.89758), control2: .init(x:  1.04761, y:  7.92916))
        p.addCurve(to: .init(x:  1.87434, y: 13.1441),  control1: .init(x:  1.5116,  y: 11.641),   control2: .init(x:  1.61464, y: 12.4654))
        p.addCurve(to: .init(x:  6.04569, y: 16.8265),  control1: .init(x:  2.57719, y: 14.9811),  control2: .init(x:  4.13573, y: 16.357))
        p.addCurve(to: .init(x:  9.24373, y: 17),       control1: .init(x:  6.75142, y: 17),       control2: .init(x:  7.58219, y: 17))
        p.addLine(to: .init(x: 13.1815, y: 17))
        p.addCurve(to: .init(x: 16.7344, y: 16.7956),  control1: .init(x: 15.0414, y: 17),       control2: .init(x: 15.9714, y: 17))
        p.addCurve(to: .init(x: 20.977,  y: 12.553),   control1: .init(x: 18.8049, y: 16.2408),  control2: .init(x: 20.4222, y: 14.6235))
        p.addCurve(to: .init(x: 21.1815, y:  9.00004), control1: .init(x: 21.1815, y: 11.79),    control2: .init(x: 21.1815, y: 10.86))
        p.addCurve(to: .init(x: 20.977,  y:  5.44713), control1: .init(x: 21.1815, y:  7.1401),  control2: .init(x: 21.1815, y:  6.21013))
        p.addCurve(to: .init(x: 16.7344, y:  1.20449), control1: .init(x: 20.4222, y:  3.37658), control2: .init(x: 18.8049, y:  1.75929))
        p.addCurve(to: .init(x: 13.1815, y:  1.00004), control1: .init(x: 15.9714, y:  1.00004), control2: .init(x: 15.0414, y:  1.00004))
        p.closeSubpath()
    }

    /// Gaze down-right — upper-right corner pulls toward the viewer (Figma 1087:324).
    private static let bodyDownRight: CGPath = flippedBody { p in
        p.move(to:    .init(x: 12.9378, y:  1.00004))
        p.addLine(to: .init(x:  9.00004, y:  1.00004))
        p.addCurve(to: .init(x:  5.44712, y:  1.20449), control1: .init(x:  7.14009, y:  1.00004), control2: .init(x:  6.21012, y:  1.00004))
        p.addCurve(to: .init(x:  1.20448, y:  5.44713), control1: .init(x:  3.37657, y:  1.75929), control2: .init(x:  1.75928, y:  3.37658))
        p.addCurve(to: .init(x:  1.00004, y:  9.00004), control1: .init(x:  1.00004, y:  6.21013), control2: .init(x:  1.00004, y:  7.1401))
        p.addCurve(to: .init(x:  1.20448, y: 12.553),   control1: .init(x:  1.00004, y: 10.86),    control2: .init(x:  1.00004, y: 11.79))
        p.addCurve(to: .init(x:  5.44712, y: 16.7956),  control1: .init(x:  1.75928, y: 14.6235),  control2: .init(x:  3.37657, y: 16.2408))
        p.addCurve(to: .init(x:  9.00004, y: 17),       control1: .init(x:  6.21012, y: 17),       control2: .init(x:  7.14009, y: 17))
        p.addLine(to: .init(x: 12.9378, y: 17))
        p.addCurve(to: .init(x: 16.1358, y: 16.8265),  control1: .init(x: 14.5993, y: 17),       control2: .init(x: 15.4301, y: 17))
        p.addCurve(to: .init(x: 20.3072, y: 13.1441),  control1: .init(x: 18.0458, y: 16.357),   control2: .init(x: 19.6043, y: 14.9811))
        p.addCurve(to: .init(x: 20.876,  y:  9.99232), control1: .init(x: 20.5669, y: 12.4654),  control2: .init(x: 20.6699, y: 11.641))
        p.addCurve(to: .init(x: 21.1284, y:  6.05498), control1: .init(x: 21.1339, y:  7.92916), control2: .init(x: 21.2628, y:  6.89758))
        p.addCurve(to: .init(x: 16.876,  y:  1.23792), control1: .init(x: 20.7627, y:  3.76164), control2: .init(x: 19.1063, y:  1.88534))
        p.addCurve(to: .init(x: 12.9378, y:  1.00004), control1: .init(x: 16.0566, y:  1.00004), control2: .init(x: 15.017,  y:  1.00004))
        p.closeSubpath()
    }
}
