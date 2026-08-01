import AppKit

// MARK: - Layout calculations

extension NotchPanelController {

    var collapsedWidth: CGFloat { metrics.notchGap }

    var expandedWidth: CGFloat {
        if metrics.hasNotch {
            let timerCell = metrics.timerMaxCellWidth

            let leftMin = metrics.edgeSafe
                + metrics.cellWidth + metrics.gap
                + metrics.cellWidth + metrics.gap
                + timerCell
                + metrics.leftMinToNotch

            let rightMin = metrics.rightMinFromNotch
                + metrics.cellWidth + metrics.gap
                + metrics.cellWidth + metrics.gap
                + metrics.captureButtonWidth
                + metrics.edgeSafe

            let shoulder = max(leftMin, rightMin)
            return collapsedWidth + 2 * shoulder
        }

        // The no-notch content is a single HStack of 6 cells (5 inter-cell gaps).
        // `left` covers close + mode + timer, `right` covers archive + more + capture;
        // the trailing `.gap` on `left` is the 5th gap joining the two groups —
        // without it the panel background ends up one `gap` narrower than the
        // content and the rightmost button overflows the shape.
        let left = metrics.edgeSafe
            + metrics.cellWidth + metrics.gap
            + metrics.cellWidth + metrics.gap
            + metrics.timerCellWidth(for: model.delay.shortLabel)
            + metrics.gap

        let right = metrics.edgeSafe
            + metrics.cellWidth + metrics.gap
            + metrics.cellWidth + metrics.gap
            + metrics.captureButtonWidth

        return left + right
    }

    // Panel height is always the Archive height — animation is driven by SwiftUI progress, not setFrame.
    var archiveScrollRowHeight: CGFloat { 55 }
    var archivePanelHeight: CGFloat { metrics.panelHeight + archiveScrollRowHeight }

    var currentWidthForCurrentRoute: CGFloat {
        switch route {
        case .main:     return expandedWidth
        case .archive:  return archiveWidth
        case .cdwn:     return expandedWidth
        }
    }

    var archiveWidth: CGFloat {
        // On notched devices the Archive uses the same width as Main —
        // content scrolls inside the panel, the panel width does not change.
        if metrics.hasNotch {
            return expandedWidth
        }

        let baseSide = metrics.edgeSafe
        let swatchWidth: CGFloat = metrics.buttonHeight + 2
        let shotWidth: CGFloat = swatchWidth * 1.6
        let spacing: CGFloat = 6

        let colorCount = archiveModel.colors.count
        let shotCount = archiveModel.items.count - colorCount
        let totalCount = max(1, archiveModel.items.count)
        let contentWidth = CGFloat(colorCount) * swatchWidth
            + CGFloat(shotCount) * shotWidth
            + CGFloat(max(0, totalCount - 1)) * spacing

        let schemeControlWidth: CGFloat = 68
        let backButtonWidth: CGFloat = metrics.cellWidth

        return baseSide + backButtonWidth + metrics.gap + schemeControlWidth + metrics.gap + min(contentWidth, 300) + baseSide
    }

    func clampedWidth(_ w: CGFloat, on screen: NSScreen) -> CGFloat {
        let maxW = screen.frame.width - 16
        return min(max(w, collapsedWidth), maxW)
    }

    func frameForWidth(_ width: CGFloat, on screen: NSScreen?, height: CGFloat? = nil) -> NSRect {
        // Window dimensions are scaled by panelScale to match the SwiftUI
        // scaleEffect applied to the content (notch style on notch-less screens).
        // panelScale == 1 for real notch / rounded, so those are unaffected.
        let s = metrics.panelScale
        let w = width * s
        let h = (height ?? metrics.panelHeight) * s
        guard let screen else { return NSRect(x: 0, y: 0, width: w, height: h) }

        let sf = screen.frame
        let margin = snapToPixel(8, scale: metrics.scale)

        var x = sf.midX - w / 2
        x = max(sf.minX + margin, min(x, sf.maxX - margin - w))
        x = snapToPixel(x, scale: metrics.scale)

        let topInsetNoNotch = snapToPixel(metrics.outerSideInset * s, scale: metrics.scale)

        let y: CGFloat
        if metrics.pinnedToTopEdge {
            // Panel is anchored to the top edge of the screen; it grows downward when expanded.
            y = snapToPixel(sf.maxY - h, scale: metrics.scale)
        } else {
            y = snapToPixel(screen.visibleFrame.maxY - h - topInsetNoNotch, scale: metrics.scale)
        }

        return NSRect(x: x, y: y, width: snapToPixel(w, scale: metrics.scale), height: snapToPixel(h, scale: metrics.scale))
    }

    func frameNoNotchHiddenAbove(width: CGFloat, on screen: NSScreen?, height: CGFloat? = nil) -> NSRect {
        let s = metrics.panelScale
        let w = width * s
        let h = (height ?? metrics.panelHeight) * s
        guard let screen else { return NSRect(x: 0, y: 0, width: w, height: h) }

        let sf = screen.frame
        let margin = snapToPixel(8, scale: metrics.scale)

        var x = sf.midX - w / 2
        x = max(sf.minX + margin, min(x, sf.maxX - margin - w))
        x = snapToPixel(x, scale: metrics.scale)

        let y = snapToPixel(sf.maxY + metrics.pixel, scale: metrics.scale)
        return NSRect(x: x, y: y, width: snapToPixel(w, scale: metrics.scale), height: snapToPixel(h, scale: metrics.scale))
    }

    /// Hidden start/end frame for the notch tab: the visible frame nudged up by
    /// just the visible content height (the Main strip). The tab is pinned to the
    /// top edge, so a full slide-from-above (`frameNoNotchHiddenAbove`) plays out
    /// mostly off-screen and reads as a pop; nudging up by only the content
    /// height makes the whole reveal/close the content wiping in/out at the edge.
    func frameNotchTabHidden(width: CGFloat, on screen: NSScreen?) -> NSRect {
        var f = frameForWidth(width, on: screen, height: archivePanelHeight)
        f.origin.y += metrics.panelHeight * metrics.panelScale
        return f
    }
}

// MARK: - Pixel snapping

private func snapToPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
    let s = max(scale, 1)
    return (value * s).rounded() / s
}

// MARK: - Notch helpers

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let num = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(num.uint32Value)
    }
}
