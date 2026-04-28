import AppKit
import OSLog

// MARK: - NotchMetrics

/// Geometric metrics for the panel, computed from a specific NSScreen.
/// Consumed by NotchPanelController, NotchPanelView, and NotchTrayView.
struct NotchMetrics {

    // MARK: Screen

    /// Screen backing scale factor.
    let scale: CGFloat

    // MARK: Notch

    /// Whether the screen has a physical notch cutout.
    let hasNotch: Bool

    /// Width of the notch gap (notchGapWidth of the screen).
    let notchGap: CGFloat

    // MARK: Panel geometry

    /// Height of the panel.
    let panelHeight: CGFloat

    /// Panel corner radius (no-notch devices only).
    let panelRadius: CGFloat

    /// Inset from the outer edge of the screen to the panel (no-notch).
    let outerSideInset: CGFloat

    // MARK: Layout constants

    /// Horizontal safe margin along the panel shoulders.
    let edgeSafe: CGFloat

    /// Minimum gap from the left shoulder to the notch.
    let leftMinToNotch: CGFloat

    /// Minimum gap from the notch to the right shoulder.
    let rightMinFromNotch: CGFloat

    // MARK: Cell sizes

    /// Base width of an icon cell (xmark, photo.stack, ellipsis…).
    let cellWidth: CGFloat

    /// Height and width of the icon inside a cell.
    let iconSize: CGFloat

    /// Inter-cell spacing.
    let gap: CGFloat

    // MARK: Timer cell

    /// Gap between the timer icon and the digit label.
    let timerIconToValueGap: CGFloat

    /// Width of the two-character timer value text.
    let timerValueWidth: CGFloat

    /// Leading inset of the timer cell when digits are visible.
    let timerLeadingInsetWithValue: CGFloat

    /// Trailing inset of the timer cell when digits are visible.
    let timerTrailingInsetWithValue: CGFloat

    // MARK: Capture button

    /// Width of the Capture button.
    let captureButtonWidth: CGFloat

    // MARK: Button (tray)

    /// Height of tray swatch buttons.
    let buttonHeight: CGFloat

    /// Corner radius of tray buttons.
    let buttonRadius: CGFloat

    // MARK: Pixel

    /// One physical pixel expressed in logical units.
    var pixel: CGFloat { 1.0 / max(scale, 1) }

    // MARK: - Timer cell helpers

    /// Maximum timer cell width (two-digit label; used for notch expandedWidth).
    var timerMaxCellWidth: CGFloat {
        timerLeadingInsetWithValue + iconSize + timerIconToValueGap + timerValueWidth + timerTrailingInsetWithValue
    }

    /// Width of the digit portion of the timer for a given shortLabel.
    func timerDigitsWidth(for shortLabel: String?) -> CGFloat {
        switch shortLabel?.count ?? 0 {
        case 0: return 0
        case 1: return 8
        default: return timerValueWidth
        }
    }

    /// Total timer cell width for a given shortLabel.
    func timerCellWidth(for shortLabel: String?) -> CGFloat {
        guard shortLabel != nil else { return cellWidth }
        return timerLeadingInsetWithValue + iconSize + timerIconToValueGap + timerDigitsWidth(for: shortLabel) + timerTrailingInsetWithValue
    }

    // MARK: - Factory

    static func from(screen: NSScreen) -> NotchMetrics {
        let scale = screen.backingScaleFactor
        let notchGap = screen.notchGapWidth
        let hasNotch = notchGap > 0

        return NotchMetrics(
            scale: scale,
            hasNotch: hasNotch,
            notchGap: notchGap,
            panelHeight: 34,
            panelRadius: 10,
            outerSideInset: 5,
            edgeSafe: hasNotch ? 20 : 5,
            leftMinToNotch: 36,
            rightMinFromNotch: 12,
            cellWidth: 32,
            iconSize: 24,
            gap: 4,
            timerIconToValueGap: 2,
            timerValueWidth: 16,
            timerLeadingInsetWithValue: 4,
            timerTrailingInsetWithValue: 8,
            captureButtonWidth: 71,
            buttonHeight: 24,
            buttonRadius: 6
        )
    }

    static func fallback() -> NotchMetrics {
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            return from(screen: screen)
        }
        // No screens available (sleep, logout, or headless test).
        // Return safe hardcoded constants for a notched MacBook Pro.
        Log.metrics.warning("No screens available — using hardcoded fallback defaults.")
        return NotchMetrics(
            scale: 2.0,
            hasNotch: true,
            notchGap: 184,
            panelHeight: 34,
            panelRadius: 10,
            outerSideInset: 5,
            edgeSafe: 20,
            leftMinToNotch: 36,
            rightMinFromNotch: 12,
            cellWidth: 32,
            iconSize: 24,
            gap: 4,
            timerIconToValueGap: 2,
            timerValueWidth: 16,
            timerLeadingInsetWithValue: 4,
            timerTrailingInsetWithValue: 8,
            captureButtonWidth: 71,
            buttonHeight: 24,
            buttonRadius: 6
        )
    }
}

// MARK: - NSScreen + notchGapWidth

extension NSScreen {
    /// Width of the notch gap in logical pixels.
    /// Returns 0 if there is no notch.
    var notchGapWidth: CGFloat {
        guard #available(macOS 12.0, *) else { return 0 }
        let safeInsets = safeAreaInsets
        guard safeInsets.top > 0 else { return 0 }
        if let leftRect = auxiliaryTopLeftArea, let rightRect = auxiliaryTopRightArea {
            let totalWidth = frame.width
            let usable = leftRect.width + rightRect.width
            return max(0, totalWidth - usable)
        }
        return 0
    }
}
