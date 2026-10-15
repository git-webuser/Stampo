import CoreGraphics

/// A scrollbar says an area owns a scroller, not that its content overflows.
/// Web areas expose neither bar reliably, so both directions remain possible.
nonisolated enum ScrollDirectionHint {
    static func possibleAxes(ancestors: [ScrollAncestorCandidate<Int>], windowBounds: CGRect) -> Set<ScrollAxis> {
        var axes: Set<ScrollAxis> = []
        for ancestor in ancestors where ScrollAncestorResolver.isSuitable(
            role: ancestor.role, frame: ancestor.frame, windowBounds: windowBounds
        ) {
            if ancestor.hasHorizontalScrollBar { axes.insert(.horizontal) }
            if ancestor.hasVerticalScrollBar { axes.insert(.vertical) }
            if ancestor.role == "AXWebArea" { axes.formUnion([.vertical, .horizontal]) }
        }
        return axes
    }

    static func shown(possible: Set<ScrollAxis>?, setting: ScrollDirection) -> ScrollDirection {
        if possible == [.vertical] { return .down }
        if possible == [.horizontal] { return .right }
        return setting
    }

    static func displayed(chosenByUser: Bool, possible: Set<ScrollAxis>?, setting: ScrollDirection) -> ScrollDirection {
        chosenByUser ? setting : shown(possible: possible, setting: setting)
    }

    /// Browser AX trees can be partial and report a bar for content that cannot
    /// move that way. The setting is a better hint until the capture probes it.
    static func usesAccessibility(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return true }
        return !ScrollWebPage.browserBundles.contains(bundleIdentifier)
    }
}
