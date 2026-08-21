import CoreGraphics

/// The rules behind the gradient's stop bar.
///
/// They live outside the view because the row's logic was the problem, not its
/// looks. First it acted on the end of the list whatever the user pointed at:
/// "+" appended, "−" took the last one away, and order could not be changed at
/// all. Selecting a stop fixed half of that; the other half was that stops were
/// spread **evenly**, so their order was the only thing anyone could change —
/// "this colour holds to the middle and then falls away" could not be said.
///
/// With a position per stop, order stops being a separate idea: it *is* the
/// position. Every function here keeps the list sorted and returns it unchanged
/// when what was asked for is not allowed, so a caller can hand the result
/// straight back to the model.
nonisolated enum GradientStops {
    /// Two is a gradient; below that it is a colour. Eight is what the bar can
    /// show without the handles overlapping at the inspector's own width.
    static let minimum = 2
    static let maximum = 8

    /// A stop at `location`, coloured by what the ramp already shows there — so
    /// adding one changes nothing until it is moved or recoloured, which is
    /// what "add a handle" should mean.
    static func inserted(into stops: [Presentation.Stop],
                         at location: CGFloat) -> [Presentation.Stop] {
        guard stops.count < maximum else { return stops }
        let place = clampedLocation(location)
        return sorted(stops + [Presentation.Stop(color(of: stops, at: place), at: place)])
    }

    /// The stop the user picked, not the one that happens to be last.
    static func removed(from stops: [Presentation.Stop], at index: Int) -> [Presentation.Stop] {
        guard stops.count > minimum, stops.indices.contains(index) else { return stops }
        var result = stops
        result.remove(at: index)
        return result
    }

    /// Moves one stop along the ramp. The list is re-sorted, so dragging a stop
    /// past its neighbour reorders the gradient — there is nothing else to
    /// reorder with.
    ///
    /// Returns the moved stop's new index alongside the list, because the
    /// caller is holding a selection that has just been re-sorted under it.
    static func moved(_ stops: [Presentation.Stop], at index: Int,
                      to location: CGFloat) -> (stops: [Presentation.Stop], index: Int) {
        guard stops.indices.contains(index) else { return (stops, index) }
        var moved = stops
        moved[index].location = clampedLocation(location)
        let target = moved[index]
        let result = sorted(moved)
        // Same colour and same position can appear twice; take the first that
        // is not another stop the caller already had in that spot.
        let newIndex = result.firstIndex { $0 == target } ?? index
        return (result, newIndex)
    }

    static func recolored(_ stops: [Presentation.Stop], at index: Int,
                          to color: Presentation.Color) -> [Presentation.Stop] {
        guard stops.indices.contains(index) else { return stops }
        var result = stops
        result[index].color = color
        return result
    }

    /// Where the selection lands after the list changed under it.
    static func clampedSelection(_ index: Int, in stops: [Presentation.Stop]) -> Int {
        guard !stops.isEmpty else { return 0 }
        return min(max(0, index), stops.count - 1)
    }

    static func sorted(_ stops: [Presentation.Stop]) -> [Presentation.Stop] {
        stops.sorted { $0.location < $1.location }
    }

    static func clampedLocation(_ location: CGFloat) -> CGFloat {
        guard location.isFinite else { return 0 }
        return min(1, max(0, location))
    }

    /// The colour the ramp shows at `location` — the same linear blend Core
    /// Graphics draws between two stops, so a stop added on the bar lands in
    /// the colour that was already under the pointer.
    static func color(of stops: [Presentation.Stop], at location: CGFloat) -> Presentation.Color {
        let ordered = sorted(stops)
        guard let first = ordered.first, let last = ordered.last else { return .white }
        let place = clampedLocation(location)
        if place <= first.location { return first.color }
        if place >= last.location { return last.color }
        for (left, right) in zip(ordered, ordered.dropFirst()) where place <= right.location {
            let span = right.location - left.location
            guard span > 0 else { return right.color }
            return blend(left.color, right.color, amount: (place - left.location) / span)
        }
        return last.color
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
