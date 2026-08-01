import SwiftUI

struct NotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        let vbW: CGFloat = 536
        let vbH: CGFloat = 34

        let sx = rect.width / vbW
        let sy = rect.height / vbH

        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var path = Path()

        path.move(to: p(7, 0))

        path.addCurve(
            to: p(12.27, 0.544967),
            control1: p(9.80026, 0),
            control2: p(11.2004, 0)
        )
        path.addCurve(
            to: p(14.455, 2.73005),
            control1: p(13.2108, 1.02433),
            control2: p(13.9757, 1.78924)
        )
        path.addCurve(
            to: p(15, 8),
            control1: p(15, 3.79961),
            control2: p(15, 5.19974)
        )
        path.addLine(to: p(15, 18))
        path.addCurve(
            to: p(16.0899, 28.5399),
            control1: p(15, 23.6005),
            control2: p(15, 26.4008)
        )
        path.addCurve(
            to: p(20.4601, 32.9101),
            control1: p(17.0487, 30.4215),
            control2: p(18.5785, 31.9513)
        )
        path.addCurve(
            to: p(31, 34),
            control1: p(22.5992, 34),
            control2: p(25.3995, 34)
        )

        path.addLine(to: p(505, 34))

        path.addCurve(
            to: p(515.54, 32.9101),
            control1: p(510.601, 34),
            control2: p(513.401, 34)
        )
        path.addCurve(
            to: p(519.91, 28.5399),
            control1: p(517.422, 31.9513),
            control2: p(518.951, 30.4215)
        )
        path.addCurve(
            to: p(521, 18),
            control1: p(521, 26.4008),
            control2: p(521, 23.6005)
        )
        path.addLine(to: p(521, 8))
        path.addCurve(
            to: p(521.545, 2.73005),
            control1: p(521, 5.19974),
            control2: p(521, 3.79961)
        )
        path.addCurve(
            to: p(523.73, 0.544967),
            control1: p(522.024, 1.78924),
            control2: p(522.789, 1.02433)
        )
        path.addCurve(
            to: p(529, 0),
            control1: p(524.8, 0),
            control2: p(526.2, 0)
        )

        path.addLine(to: p(7, 0))
        path.closeSubpath()

        return path
    }
}

// MARK: - NotchTabShape

/// Notch silhouette for notch-less screens: a flat top flush with the screen
/// edge, small top corners, and the notch's tapering bottom "shoulders"
/// (скосы). Unlike `PanelMorphShape`, the corners are fixed-size (a 9-slice):
/// the bottom shoulders stay anchored to the bottom edge and the side walls
/// stretch, so the corners never distort with width and the same shape serves
/// both Main and the taller Archive (the height is driven by the morph progress).
///
/// Corner geometry is lifted verbatim from `NotchShape` (a 536×34 design):
/// the bottom shoulder occupies the bottom 16pt, the top corners the top 8pt,
/// and the wall between them stretches with height.
struct NotchTabShape: Shape {
    func path(in rect: CGRect) -> Path {
        let ox = rect.minX
        let oy = rect.minY
        let W  = rect.width
        let H  = rect.height

        // Left/top-anchored point (y measured from the top).
        func L(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x, y: oy + y) }
        // Left/bottom-anchored point (y in the design's 18…34 shoulder band).
        func B(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x, y: oy + H - (34 - y)) }
        // Right mirror of L / B (x reflected across the width).
        func R(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + W - x, y: oy + y) }
        func RB(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + W - x, y: oy + H - (34 - y)) }

        var p = Path()
        // Top edge + top-left corner down to the wall.
        p.move(to: L(7, 0))
        p.addCurve(to: L(12.27, 0.545),  control1: L(9.8, 0),       control2: L(11.2, 0))
        p.addCurve(to: L(14.455, 2.73),  control1: L(13.21, 1.024), control2: L(13.98, 1.789))
        p.addCurve(to: L(15, 8),         control1: L(15, 3.8),      control2: L(15, 5.2))
        p.addLine(to: B(15, 18))
        // Bottom-left shoulder (скос).
        p.addCurve(to: B(16.09, 28.54),  control1: B(15, 23.601),    control2: B(15, 26.401))
        p.addCurve(to: B(20.46, 32.91),  control1: B(17.049, 30.422), control2: B(18.579, 31.951))
        p.addCurve(to: B(31, 34),        control1: B(22.599, 34),     control2: B(25.4, 34))
        // Bottom edge.
        p.addLine(to: RB(31, 34))
        // Bottom-right shoulder.
        p.addCurve(to: RB(20.46, 32.91), control1: RB(25.4, 34),      control2: RB(22.599, 34))
        p.addCurve(to: RB(16.09, 28.54), control1: RB(18.579, 31.951), control2: RB(17.049, 30.422))
        p.addCurve(to: RB(15, 18),       control1: RB(15, 26.401),    control2: RB(15, 23.601))
        // Right wall up + top-right corner.
        p.addLine(to: R(15, 8))
        p.addCurve(to: R(14.455, 2.73),  control1: R(15, 5.2),       control2: R(15, 3.8))
        p.addCurve(to: R(12.27, 0.545),  control1: R(13.98, 1.789),  control2: R(13.21, 1.024))
        p.addCurve(to: R(7, 0),          control1: R(11.2, 0),       control2: R(9.8, 0))
        p.closeSubpath()
        return p
    }
}
