import CoreGraphics

/// The list operations behind the gradient's stop row.
///
/// They live outside the view because the old row's logic was the problem, not
/// its looks: "+" always appended a darkened copy of the last colour, "−"
/// always took the last one away, and there was no way to say which stop you
/// meant — so a three-stop gradient could not be edited in the middle, and a
/// stop could not be moved at all. Written here, each operation is one function
/// with an obvious answer, and the tests can ask for it directly.
///
/// Every function returns the list unchanged when what was asked for is not
/// allowed, so a caller can hand the result straight back to the model.
nonisolated enum GradientStops {
    /// Two is a gradient; below that it is a colour. Five is what the row can
    /// show at the inspector's minimum width.
    static let minimum = 2
    static let maximum = 5

    /// A new stop right after `index`, coloured halfway between it and the
    /// stop that follows — which is what "add a stop" means on a ramp: the
    /// gradient does not change shape, it gains a handle where you asked for
    /// one. After the last stop there is nothing to meet, so the ramp carries
    /// on in the direction it was already going.
    static func inserted(into stops: [Presentation.Color], after index: Int) -> [Presentation.Color] {
        guard stops.count < maximum, stops.indices.contains(index) else { return stops }
        var result = stops
        let color: Presentation.Color
        if index + 1 < stops.count {
            color = blend(stops[index], stops[index + 1], amount: 0.5)
        } else {
            color = blend(stops[index], .black, amount: 0.35)
        }
        result.insert(color, at: index + 1)
        return result
    }

    /// The stop the user picked, not the one that happens to be last.
    static func removed(from stops: [Presentation.Color], at index: Int) -> [Presentation.Color] {
        guard stops.count > minimum, stops.indices.contains(index) else { return stops }
        var result = stops
        result.remove(at: index)
        return result
    }

    /// Moves one stop to another slot, keeping the rest in order. `to` is the
    /// slot the stop ends up in, counted in the finished list — which is what
    /// both a drag and a "move left" mean, and it saves every caller the
    /// off-by-one that the insert-after-remove spelling invites.
    static func moved(_ stops: [Presentation.Color], from: Int, to: Int) -> [Presentation.Color] {
        guard stops.indices.contains(from), stops.indices.contains(to), from != to else { return stops }
        var result = stops
        let stop = result.remove(at: from)
        result.insert(stop, at: to)
        return result
    }

    /// Where the selection lands after the list changed under it: the same
    /// stop if it survived, otherwise the nearest one that exists. A list is
    /// never empty here, so this always names a real stop.
    static func clampedSelection(_ index: Int, in stops: [Presentation.Color]) -> Int {
        guard !stops.isEmpty else { return 0 }
        return min(max(0, index), stops.count - 1)
    }

    static func blend(_ lhs: Presentation.Color,
                      _ rhs: Presentation.Color,
                      amount: CGFloat) -> Presentation.Color {
        let t = min(1, max(0, amount))
        return Presentation.Color(
            red: lhs.red + (rhs.red - lhs.red) * t,
            green: lhs.green + (rhs.green - lhs.green) * t,
            blue: lhs.blue + (rhs.blue - lhs.blue) * t,
            alpha: lhs.alpha + (rhs.alpha - lhs.alpha) * t
        )
    }
}
