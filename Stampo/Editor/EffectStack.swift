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
        case amount, scale, angle, color
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
        case .grain: return "Grain"
        }
    }

    /// The glyph for the row and for the tile in the grid.
    static func symbol(for kind: Kind) -> String {
        switch kind {
        case .grain: return "circle.grid.3x3.fill"
        }
    }

    /// A fresh effect of this kind, with the values it should start at.
    ///
    /// The seed is drawn once, here, and never again: it is what keeps the
    /// noise in the preview and the noise in the exported file the same noise.
    static func make(_ kind: Kind, seed: UInt32 = .random(in: 0...UInt32.max)) -> Effect {
        switch kind {
        case .grain:
            return Effect(id: UUID(), kind: .grain, isEnabled: true,
                          amount: 0.35, scale: 0.0015, angle: 0,
                          color: .black, seed: seed)
        }
    }

    static func parameters(for kind: Kind) -> [ParameterInfo] {
        switch kind {
        case .grain:
            return [
                ParameterInfo(parameter: .amount, titleKey: "Strength",
                              systemImage: "dial.medium",
                              range: 0...1, step: 0.01),
                // A grain measured in pixels would be a different grain in the
                // preview and in the file, which is why every size here is a
                // fraction of the short side. 0.001 of 1200px is about one
                // pixel; 0.01 is a coarse, deliberate texture.
                ParameterInfo(parameter: .scale, titleKey: "Grain Size",
                              systemImage: "circle.dotted",
                              range: 0.0005...0.01, step: 0.0005)
            ]
        }
    }

    // MARK: Values

    static func value(_ parameter: Parameter, of effect: Effect) -> CGFloat {
        switch parameter {
        case .amount: return effect.amount
        case .scale:  return effect.scale
        case .angle:  return effect.angle
        case .color:  return 0
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
        case .angle:  result.angle = clamped
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
