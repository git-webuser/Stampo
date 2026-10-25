import SwiftUI

/// The grid of dots on the Arc card's work surface. It stands still: tied to
/// the area on screen, so neither zoom nor pan moves it, and it exists only as
/// a view — no renderer or export reads it.
struct ArcDotGrid: View {
    var body: some View {
        Canvas { context, size in
            let diameter = ArcFrameLayout.dotDiameter
            var dots = Path()
            for center in ArcFrameLayout.dotCenters(in: size) {
                dots.addEllipse(in: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                           width: diameter, height: diameter))
            }
            context.fill(dots, with: .color(.primary.opacity(ArcFrameLayout.dotOpacity)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
