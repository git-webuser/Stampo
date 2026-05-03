import AppKit
import QuartzCore

// MARK: - Public types

enum EyeDirection: Equatable {
    case leftUp, leftCenter, leftDown
    case rightUp, rightCenter, rightDown
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
    private let leftPupilLayer   = CALayer()
    private let rightPupilLayer  = CALayer()

    // MARK: Geometry (all in CALayer coords: y from bottom, view 20×16)

    private enum G {
        static let eyeR:    CGFloat = 2
        static let pupilR:  CGFloat = 0.5

        // Eye X positions: left-series and right-series
        static let lEyeX: (CGFloat, CGFloat) = (5, 12)   // left-eye, right-eye when gaze=left
        static let rEyeX: (CGFloat, CGFloat) = (8, 15)   // gaze=right

        // Eye Y positions: "up" file has eyes lower (y=9), up-1 higher (y=11)
        static let eyeYlo: CGFloat = 9   // "up" variant (eyes drop, pupils look up)
        static let eyeYmd: CGFloat = 10  // center
        static let eyeYhi: CGFloat = 11  // "up-1" variant (eyes rise, pupils look down)

        // Arc geometry (closed / wink eyes). All arcs sit at y≈9.75, arch peak at y≈10.25.
        // Represented as quadratic bezier: start → control → end (in parent layer coords).
        struct Arc {
            let s, c, e: CGPoint
            var path: CGPath {
                let p = CGMutablePath()
                p.move(to: s)
                p.addQuadCurve(to: e, control: c)
                return p
            }
        }

        static let arcY: CGFloat     = 9.75
        static let arcTop: CGFloat   = 10.25

        // left-series sleep arcs
        static let lsL = Arc(s: .init(x: 4,  y: arcY), c: .init(x: 5.5,  y: arcTop), e: .init(x: 7,  y: arcY))
        static let lsR = Arc(s: .init(x: 10, y: arcY), c: .init(x: 11.5, y: arcTop), e: .init(x: 13, y: arcY))
        // right-series sleep arcs
        static let rsL = Arc(s: .init(x: 7,  y: arcY), c: .init(x: 8.5,  y: arcTop), e: .init(x: 10, y: arcY))
        static let rsR = Arc(s: .init(x: 13, y: arcY), c: .init(x: 14.5, y: arcTop), e: .init(x: 16, y: arcY))
    }

    // MARK: State

    private var eyesOpen     = false
    private var sequenceGen  = 0
    private var blinkTimer:  Timer?

    /// Direction the eyes were in the last time they were open.
    /// Used to reopen eyes at the same position after sleep, and to drive
    /// the celebrating sequence without an external hint from NotchHoverController.
    private var lastOpenDirection: EyeDirection = .leftCenter

    /// leftSeries value of the most recent sleep arcs.
    /// Used to reopen eyes on the same horizontal side after waking up.
    private var lastArcIsLeft: Bool = true

    private var ink:       CGColor = CGColor(gray: 0.05, alpha: 1)
    private var pupilFill: CGColor = CGColor(gray: 1,    alpha: 1)

    // MARK: Init

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }
    deinit { blinkTimer?.invalidate() }

    // MARK: Setup

    private func setup() {
        wantsLayer = true

        // Body
        bodyLayer.path      = NSBezierPath(roundedRect: .init(x: 1, y: 1, width: 18, height: 14),
                                            xRadius: 5, yRadius: 5).cgPath
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

        // Pupil layers
        let d = G.pupilR * 2
        for pupil in [leftPupilLayer, rightPupilLayer] {
            pupil.bounds       = CGRect(x: 0, y: 0, width: d, height: d)
            pupil.cornerRadius = G.pupilR
            pupil.isHidden     = true
            layer!.addSublayer(pupil)
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
        ink       = dark ? CGColor(gray: 1.0,  alpha: 0.88) : CGColor(gray: 0.05, alpha: 1.0)
        pupilFill = dark ? CGColor(gray: 0.20, alpha: 1.0)  : CGColor(gray: 1.0,  alpha: 1.0)

        noAnim {
            self.bodyLayer.strokeColor         = self.ink
            self.leftPupilLayer.backgroundColor  = self.pupilFill
            self.rightPupilLayer.backgroundColor = self.pupilFill
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

    /// Show sleeping arcs on both eyes. Resets all transforms.
    private func applyArcs(leftSeries: Bool) {
        eyesOpen = false
        lastArcIsLeft = leftSeries
        let lArc = leftSeries ? G.lsL : G.rsL
        let rArc = leftSeries ? G.lsR : G.rsR

        noAnim {
            // Reset any scale transform left over from squeeze / pop
            self.leftEyeLayer.transform  = CATransform3DIdentity
            self.rightEyeLayer.transform = CATransform3DIdentity

            self.leftEyeLayer.path       = lArc.path
            self.leftEyeLayer.fillColor  = .clear
            self.leftEyeLayer.strokeColor = self.ink

            self.rightEyeLayer.path       = rArc.path
            self.rightEyeLayer.fillColor  = .clear
            self.rightEyeLayer.strokeColor = self.ink

            self.leftPupilLayer.isHidden  = true
            self.rightPupilLayer.isHidden = true
        }
    }

    /// Set open-eye circle path + pupil position, optionally animating a spring pop.
    private func applyOpenEyes(dir: EyeDirection, popAnim: Bool) {
        eyesOpen = true
        lastOpenDirection = dir
        let (lc, rc, lp, rp) = eyeConfig(dir)

        noAnim {
            self.leftEyeLayer.transform  = CATransform3DIdentity
            self.rightEyeLayer.transform = CATransform3DIdentity

            self.setCirclePath(self.leftEyeLayer,  center: lc)
            self.setCirclePath(self.rightEyeLayer, center: rc)

            self.leftEyeLayer.fillColor   = self.ink
            self.leftEyeLayer.strokeColor = .clear
            self.rightEyeLayer.fillColor  = self.ink
            self.rightEyeLayer.strokeColor = .clear

            self.leftPupilLayer.position  = lp
            self.rightPupilLayer.position = rp
            self.leftPupilLayer.isHidden  = false
            self.rightPupilLayer.isHidden = false

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

    /// Apply wink: one eye closes to arc, the other stays open.
    private func applyWink(leftWinks: Bool) {
        noAnim {
            if leftWinks {
                // Left eye → arc
                self.leftEyeLayer.path        = G.rsL.path
                self.leftEyeLayer.fillColor   = .clear
                self.leftEyeLayer.strokeColor = self.ink
                self.leftPupilLayer.isHidden  = true
                // Right stays open, pupil shifts inward
                let rc = CGPoint(x: G.rEyeX.1, y: G.eyeYmd)
                self.setCirclePath(self.rightEyeLayer, center: rc)
                self.rightEyeLayer.fillColor   = self.ink
                self.rightEyeLayer.strokeColor = .clear
                self.rightPupilLayer.position  = CGPoint(x: rc.x - 0.5, y: rc.y)
                self.rightPupilLayer.isHidden  = false
            } else {
                // Right eye → arc
                self.rightEyeLayer.path        = G.lsR.path
                self.rightEyeLayer.fillColor   = .clear
                self.rightEyeLayer.strokeColor = self.ink
                self.rightPupilLayer.isHidden  = true
                // Left stays open
                let lc = CGPoint(x: G.lEyeX.0, y: G.eyeYmd)
                self.setCirclePath(self.leftEyeLayer, center: lc)
                self.leftEyeLayer.fillColor   = self.ink
                self.leftEyeLayer.strokeColor = .clear
                self.leftPupilLayer.position  = CGPoint(x: lc.x - 0.5, y: lc.y)
                self.leftPupilLayer.isHidden  = false
            }
        }
    }

    // MARK: - Eye movement

    private func animateMoveEyes(to dir: EyeDirection, duration: CFTimeInterval) {
        lastOpenDirection = dir
        let (lc, rc, lp, rp) = eyeConfig(dir)

        animPath(leftEyeLayer,  to: circlePath(center: lc), dur: duration)
        animPath(rightEyeLayer, to: circlePath(center: rc), dur: duration)
        animPos(leftPupilLayer,  to: lp, dur: duration)
        animPos(rightPupilLayer, to: rp, dur: duration)
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

        // Set model to 0 so when animation ends, 0 is shown (arcs will reset to 1 right after)
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

    // MARK: - Path helpers

    private func setCirclePath(_ layer: CAShapeLayer, center: CGPoint) {
        layer.path = circlePath(center: center)
    }

    private func circlePath(center: CGPoint) -> CGPath {
        let r = G.eyeR
        return CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                        width: r * 2, height: r * 2), transform: nil)
    }

    // MARK: - Eye config

    private func eyeConfig(_ dir: EyeDirection) -> (lEye: CGPoint, rEye: CGPoint,
                                                      lPup: CGPoint, rPup: CGPoint) {
        let lx:     CGFloat
        let rx:     CGFloat
        let pdx:    CGFloat  // pupil x offset from eye center
        let ey:     CGFloat
        let pdy:    CGFloat  // pupil y offset from eye center

        switch dir {
        case .leftCenter:  lx = G.lEyeX.0; rx = G.lEyeX.1; pdx = +0.5; ey = G.eyeYmd; pdy =  0
        case .leftUp:      lx = G.lEyeX.0; rx = G.lEyeX.1; pdx = +0.5; ey = G.eyeYlo; pdy = +0.5
        case .leftDown:    lx = G.lEyeX.0; rx = G.lEyeX.1; pdx = +0.5; ey = G.eyeYhi; pdy = -0.5
        case .rightCenter: lx = G.rEyeX.0; rx = G.rEyeX.1; pdx = -0.5; ey = G.eyeYmd; pdy =  0
        case .rightUp:     lx = G.rEyeX.0; rx = G.rEyeX.1; pdx = -0.5; ey = G.eyeYlo; pdy = +0.5
        case .rightDown:   lx = G.rEyeX.0; rx = G.rEyeX.1; pdx = -0.5; ey = G.eyeYhi; pdy = -0.5
        }

        return (CGPoint(x: lx,       y: ey),
                CGPoint(x: rx,       y: ey),
                CGPoint(x: lx + pdx, y: ey + pdy),
                CGPoint(x: rx + pdx, y: ey + pdy))
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
}
