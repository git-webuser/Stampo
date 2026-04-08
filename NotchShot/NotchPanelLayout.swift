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

        let left = metrics.edgeSafe
            + metrics.cellWidth + metrics.gap
            + metrics.cellWidth + metrics.gap
            + metrics.timerCellWidth(for: model.delay.shortLabel)

        let right = metrics.edgeSafe
            + metrics.cellWidth + metrics.gap
            + metrics.cellWidth + metrics.gap
            + metrics.captureButtonWidth

        return left + right
    }

    // Панель всегда имеет высоту Tray — анимация через SwiftUI progress, не через setFrame
    var trayScrollRowHeight: CGFloat { 55 }
    var trayPanelHeight: CGFloat { metrics.panelHeight + trayScrollRowHeight }

    var currentWidthForCurrentRoute: CGFloat {
        switch route {
        case .main:  return expandedWidth
        case .tray:  return trayWidth
        case .cdwn:  return expandedWidth
        }
    }

    var trayWidth: CGFloat {
        // На устройствах с нотчем Tray использует ту же ширину что и Main —
        // контент скроллируется внутри, ширина панели не меняется.
        if metrics.hasNotch {
            return expandedWidth
        }

        let baseSide = metrics.edgeSafe
        let swatchWidth: CGFloat = metrics.buttonHeight + 2
        let shotWidth: CGFloat = swatchWidth * 1.6
        let spacing: CGFloat = 6

        let colorCount = trayModel.colors.count
        let shotCount = trayModel.items.count - colorCount
        let totalCount = max(1, trayModel.items.count)
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
        let h = height ?? metrics.panelHeight
        guard let screen else { return NSRect(x: 0, y: 0, width: width, height: h) }

        let sf = screen.frame
        let margin = snapToPixel(8, scale: metrics.scale)

        var x = sf.midX - width / 2
        x = max(sf.minX + margin, min(x, sf.maxX - margin - width))
        x = snapToPixel(x, scale: metrics.scale)

        let topInsetNoNotch = snapToPixel(metrics.outerSideInset, scale: metrics.scale)

        let y: CGFloat
        if metrics.hasNotch {
            // Панель прижата к верхнему краю экрана; при расширении растёт вниз
            y = snapToPixel(sf.maxY - h, scale: metrics.scale)
        } else {
            y = snapToPixel(screen.visibleFrame.maxY - h - topInsetNoNotch, scale: metrics.scale)
        }

        return NSRect(x: x, y: y, width: snapToPixel(width, scale: metrics.scale), height: snapToPixel(h, scale: metrics.scale))
    }

    func frameNoNotchHiddenAbove(width: CGFloat, on screen: NSScreen?, height: CGFloat? = nil) -> NSRect {
        let h = height ?? metrics.panelHeight
        guard let screen else { return NSRect(x: 0, y: 0, width: width, height: h) }

        let sf = screen.frame
        let margin = snapToPixel(8, scale: metrics.scale)

        var x = sf.midX - width / 2
        x = max(sf.minX + margin, min(x, sf.maxX - margin - width))
        x = snapToPixel(x, scale: metrics.scale)

        let y = snapToPixel(sf.maxY + metrics.pixel, scale: metrics.scale)
        return NSRect(x: x, y: y, width: snapToPixel(width, scale: metrics.scale), height: snapToPixel(h, scale: metrics.scale))
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
