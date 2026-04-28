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
