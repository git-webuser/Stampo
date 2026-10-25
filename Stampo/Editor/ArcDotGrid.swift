import SwiftUI

/// The grid of dots on the Arc card's work surface. It stands still: tied to
/// the area on screen, so neither zoom nor pan moves it, and it exists only as
/// a view — no renderer or export reads it.
struct ArcDotGrid: View {
    var body: some View {
        Canvas { context, size in
            let diameter = ArcFrameLayout.dotDiameter
            let shading = GraphicsContext.Shading.color(.primary.opacity(ArcFrameLayout.dotOpacity))
            // One fill a dot: a single path of a thousand ellipses rasterises
            // two to three times slower.
            for center in ArcFrameLayout.dotCenters(in: size) {
                context.fill(Path(ellipseIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                                    width: diameter, height: diameter)),
                             with: shading)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
