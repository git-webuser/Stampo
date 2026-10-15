import CoreGraphics

nonisolated enum ScrollDirectionHint {
    static func possibleAxes(ancestors: [ScrollAncestorCandidate<Int>], windowBounds: CGRect) -> Set<ScrollAxis> {
        var axes: Set<ScrollAxis> = []
        for ancestor in ancestors where ScrollAncestorResolver.isSuitable(
            role: ancestor.role, frame: ancestor.frame, windowBounds: windowBounds
        ) {
            if ancestor.hasHorizontalScrollBar { axes.insert(.horizontal) }
            if ancestor.hasVerticalScrollBar || ancestor.role == "AXWebArea" { axes.insert(.vertical) }
        }
        return axes
    }

    static func shown(possible: Set<ScrollAxis>?, setting: ScrollDirection) -> ScrollDirection {
        if possible == [.vertical] { return .down }
        if possible == [.horizontal] { return .right }
        return setting
    }

    static func turned(setting: ScrollDirection, possible: Set<ScrollAxis>?) -> ScrollDirection {
        possible?.count == 1 ? setting : setting.other
    }
}
