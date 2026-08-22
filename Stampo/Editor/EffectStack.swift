import CoreGraphics
import Foundation

/// The rules of the effect stack, with no drawing and no UI in them.
///
/// Two things live here: what a kind *is* (its defaults, the parameters it
/// actually has, and the limits of each) and what the list can do (reorder,
/// clamp). Both are answers the panel and the baker need, and neither is worth
/// discovering by reading a view.
///
/// Parameters are declared rather than switched over in the panel: a kind says
/// it has an amount and a scale, and the section grows one slider per declared
/// parameter. A case with its own payload would need a form of its own, and the
/// eleventh effect would be the eleventh form.
nonisolated enum EffectStack {
    typealias Effect = Presentation.Effect
    typealias Kind = Presentation.Effect.Kind

    /// Which of the four stored numbers a kind uses.
    enum Parameter: String, Hashable, Sendable {
        case amount, scale, angle, color, detail
    }

    /// A parameter as the panel needs it: what to call it, what to draw beside
    /// it, and where it may go. The range belongs to the kind, not to the
    /// slider — the same `scale` is a grain in one effect and a cell in
    /// another.
    struct ParameterInfo: Equatable, Sendable {
        let parameter: Parameter
        /// Localized key. Not a `LocalizedStringKey`: this type is used by the
        /// baker and by tests, neither of which imports SwiftUI.
        let titleKey: String
        let systemImage: String
        let range: ClosedRange<CGFloat>
        let step: CGFloat
    }

    // MARK: Kinds

    static func title(for kind: Kind) -> String {
        switch kind {
        case .grain:    return "Grain"
        case .dots:     return "Dots"
        case .grid:     return "Grid"
        case .stripes:  return "Stripes"
        case .vignette: return "Vignette"
        case .pixelate: return "Pixelate"
        case .dither:   return "Dither"
        case .halftone: return "Halftone"
        case .fluted:   return "Fluted Glass"
        case .glass:    return "Frosted Glass"
        case .lens:     return "Lens"
        case .ascii:    return "ASCII"
        }
    }

    /// The glyph for the row and for the tile in the grid.
    static func symbol(for kind: Kind) -> String {
        switch kind {
        case .grain:    return "circle.grid.3x3.fill"
        case .dots:     return "circle.grid.2x2.fill"
        case .grid:     return "grid"
        case .stripes:  return "line.3.horizontal"
        case .vignette: return "camera.aperture"
        case .pixelate: return "squareshape.split.2x2"
        case .dither:   return "circle.hexagongrid.fill"
        case .halftone: return "circle.grid.cross"
        case .fluted:   return "lines.measurement.vertical"
        case .glass:    return "cube.transparent"
        case .lens:     return "dot.circle.viewfinder"
        case .ascii:    return "textformat.abc"
        }
    }

    /// A fresh effect of this kind, with the values it should start at.
    ///
    /// The seed is drawn once, here, and never again: it is what keeps the
    /// noise in the preview and the noise in the exported file the same noise.
    ///
    /// The background is asked for its brightness because ink has to be seen:
    /// white dots on a white page are a control that looks broken, and that is
    /// exactly how the patterns first shipped — measured at a fortieth of their
    /// strength on a light background against a dark one.
    static func make(_ kind: Kind, over background: Presentation.Background = .none,
                     seed: UInt32 = .random(in: 0...UInt32.max)) -> Effect {
        let ink = background.contrastingInk
        func effect(amount: CGFloat, scale: CGFloat, angle: CGFloat = 0,
                    color: Presentation.Color = .black, detail: CGFloat = 0) -> Effect {
            Effect(id: UUID(), kind: kind, isEnabled: true, amount: amount,
                   scale: scale, angleInDegrees: angle, color: color,
                   detail: detail, seed: seed)
        }
        switch kind {
        // Defaults are the settings that make the effect *recognisable* on
        // sight, not the mildest ones: a new row that changes nothing reads as
        // a control that does not work.
        case .grain:    return effect(amount: 0.35, scale: 0.0015)
        case .dots:     return effect(amount: 0.18, scale: 0.04, color: ink)
        case .grid:     return effect(amount: 0.14, scale: 0.05, color: ink)
        case .stripes:  return effect(amount: 0.12, scale: 0.04,
                                      angle: 45, color: ink)
        case .vignette: return effect(amount: 0.5, scale: 0.8)
        case .pixelate: return effect(amount: 1, scale: 0.05, detail: 10)
        case .dither:   return effect(amount: 1, scale: 0.003, detail: 4)
        case .halftone: return effect(amount: 0.7, scale: 0.012)
        // Ribs stand upright, like the panel in a door — angle 0 is a rib
        // along the vertical, and turning it lays them over.
        case .fluted:   return effect(amount: 0.55, scale: 0.05, detail: 0.35)
        case .glass:    return effect(amount: 0.5, scale: 0.03)
        case .lens:     return effect(amount: 0.5, scale: 0.7)
        // The letters sit on a darkened page whatever the background was, so
        // they stay light — the veil is what they have to be seen against.
        case .ascii:    return effect(amount: 0.9, scale: 0.02, color: .white)
        }
    }

    static func parameters(for kind: Kind) -> [ParameterInfo] {
        // Sizes are fractions of the short side, never pixels: the preview is
        // baked at screen resolution and the file at its own, and a size in
        // pixels would be a different size in each. 0.001 of a 1200px canvas is
        // about one pixel.
        func strength(_ range: ClosedRange<CGFloat> = 0...1) -> ParameterInfo {
            ParameterInfo(parameter: .amount, titleKey: "Strength",
                          systemImage: "dial.medium", range: range, step: 0.01)
        }
        func size(_ titleKey: String, _ range: ClosedRange<CGFloat>,
                  step: CGFloat, symbol: String = "circle.dotted") -> ParameterInfo {
            ParameterInfo(parameter: .scale, titleKey: titleKey,
                          systemImage: symbol, range: range, step: step)
        }
        let angle = ParameterInfo(parameter: .angle, titleKey: "Angle",
                                  systemImage: "angle", range: 0...180, step: 1)
        // How many colours a quantizer leaves. A count, not a fraction: "6
        // colours" is a thing a person can picture, and 0.4 is not.
        let levels = ParameterInfo(parameter: .detail, titleKey: "Color Levels",
                                   systemImage: "circle.lefthalf.striped.horizontal",
                                   range: 2...32, step: 1)
        let color = ParameterInfo(parameter: .color, titleKey: "Pattern Color",
                                  systemImage: "paintpalette", range: 0...1, step: 1)

        switch kind {
        case .grain:
            return [strength(), size("Grain Size", 0.0005...0.01, step: 0.0005)]
        case .dots, .grid, .stripes:
            return [strength(), size("Pattern Step", 0.01...0.2, step: 0.005,
                                     symbol: "square.grid.3x3"), angle, color]
        case .vignette:
            return [strength(), size("Vignette Radius", 0.2...1.5, step: 0.05,
                                     symbol: "camera.aperture")]
        case .pixelate:
            return [size("Cell Size", 0.004...0.15, step: 0.002,
                         symbol: "squareshape.split.2x2"), levels]
        case .dither:
            // Pattern scale, not cell size: what repeats is the threshold
            // matrix, and one matrix cell is a handful of pixels.
            return [strength(), size("Pattern Scale", 0.001...0.02, step: 0.001,
                                     symbol: "squareshape.split.2x2"), levels]
        case .fluted:
            return [strength(), size("Rib Width", 0.01...0.2, step: 0.005,
                                     symbol: "lines.measurement.vertical"),
                    angle,
                    ParameterInfo(parameter: .detail, titleKey: "Relief",
                                  systemImage: "square.3.layers.3d.top.filled",
                                  range: 0...1, step: 0.01)]
        case .halftone:
            return [strength(), size("Dot Size", 0.002...0.05, step: 0.002,
                                     symbol: "circle.grid.cross"), angle]
        case .glass:
            return [strength(), size("Texture Size", 0.005...0.08, step: 0.005,
                                     symbol: "cube.transparent")]
        case .lens:
            // Negative pinches instead of bulging — one dial, both directions,
            // because "inward" is the same gesture read backwards.
            return [strength(-1...1), size("Lens Radius", 0.2...1.5, step: 0.05,
                                           symbol: "dot.circle.viewfinder")]
        case .ascii:
            return [strength(), size("Cell Size", 0.008...0.06, step: 0.002,
                                     symbol: "textformat.size"),
                    ParameterInfo(parameter: .color, titleKey: "Letter Color",
                                  systemImage: "paintpalette", range: 0...1, step: 1)]
        }
    }

    // MARK: Values

    static func value(_ parameter: Parameter, of effect: Effect) -> CGFloat {
        switch parameter {
        case .amount: return effect.amount
        case .scale:  return effect.scale
        case .angle:  return effect.angleInDegrees
        case .detail: return effect.detail
        case .color:  return 0   // a colour is not a number; the panel edits it directly
        }
    }

    /// One parameter set to a new value, held inside the kind's own limits.
    /// Clamping lives here rather than in the slider because the same value
    /// arrives from a typed number too.
    static func setting(_ parameter: Parameter, of effect: Effect,
                        to value: CGFloat) -> Effect {
        guard let info = parameters(for: effect.kind)
            .first(where: { $0.parameter == parameter }) else { return effect }
        let clamped = min(info.range.upperBound, max(info.range.lowerBound, value))
        var result = effect
        switch parameter {
        case .amount: result.amount = clamped
        case .scale:  result.scale = clamped
        case .angle:  result.angleInDegrees = clamped
        case .detail: result.detail = clamped
        case .color:  break
        }
        return result
    }

    /// Every stored number brought inside its kind's limits — for values that
    /// arrive from somewhere other than the panel.
    static func clamped(_ effect: Effect) -> Effect {
        var result = effect
        for info in parameters(for: effect.kind) {
            result = setting(info.parameter, of: result, to: value(info.parameter, of: result))
        }
        return result
    }

    // MARK: The list

    /// The stack with one effect moved, and where it ended up.
    ///
    /// `to` is an index in the list *as it stands*, which is what a row being
    /// dragged over its neighbours reports. Out-of-range indices leave the list
    /// alone rather than trapping: the drag reports whatever the pointer is
    /// over, including nowhere.
    static func moved(_ effects: [Effect], from: Int, to: Int) -> (effects: [Effect], index: Int) {
        guard effects.indices.contains(from) else { return (effects, from) }
        let target = min(effects.count - 1, max(0, to))
        guard target != from else { return (effects, from) }
        var result = effects
        let moving = result.remove(at: from)
        result.insert(moving, at: target)
        return (result, target)
    }

    /// The effects that actually change the picture. The baker asks for this,
    /// so a stack of switched-off effects costs exactly nothing.
    static func active(_ effects: [Effect]) -> [Effect] {
        effects.filter(\.isEnabled)
    }
}
