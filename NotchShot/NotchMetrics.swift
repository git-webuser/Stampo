import AppKit

// MARK: - NotchMetrics

/// Геометрические метрики панели, вычисленные из конкретного NSScreen.
/// Используются в NotchPanelController, NotchPanelView и NotchTrayView.
struct NotchMetrics {

    // MARK: Screen

    /// Масштаб экрана (backingScaleFactor).
    let scale: CGFloat

    // MARK: Notch

    /// Есть ли физическая вырезка (notch) на экране.
    let hasNotch: Bool

    /// Ширина области под нотч (notchGapWidth у экрана).
    let notchGap: CGFloat

    // MARK: Panel geometry

    /// Высота панели.
    let panelHeight: CGFloat

    /// Угловой радиус панели (только для no-notch).
    let panelRadius: CGFloat

    /// Отступ панели от внешнего края экрана (no-notch).
    let outerSideInset: CGFloat

    // MARK: Layout constants

    /// Горизонтальный отступ по краям плеч.
    let edgeSafe: CGFloat

    /// Минимальный отступ от левого плеча до нотча.
    let leftMinToNotch: CGFloat

    /// Минимальный отступ от нотча до правого плеча.
    let rightMinFromNotch: CGFloat

    // MARK: Cell sizes

    /// Базовая ширина иконочной ячейки (xmark, photo.stack, ellipsis...).
    let cellWidth: CGFloat

    /// Высота / ширина иконки внутри ячейки.
    let iconSize: CGFloat

    /// Межячеечный промежуток.
    let gap: CGFloat

    // MARK: Timer cell

    /// Промежуток между иконкой таймера и цифрами.
    let timerIconToValueGap: CGFloat

    /// Ширина текста со значением таймера (2 символа).
    let timerValueWidth: CGFloat

    /// Leading-отступ ячейки таймера, когда цифры видны.
    let timerLeadingInsetWithValue: CGFloat

    /// Trailing-отступ ячейки таймера, когда цифры видны.
    let timerTrailingInsetWithValue: CGFloat

    // MARK: Capture button

    /// Ширина кнопки «Capture».
    let captureButtonWidth: CGFloat

    // MARK: Button (tray)

    /// Высота кнопок-свотчей в трее.
    let buttonHeight: CGFloat

    /// Угловой радиус кнопок в трее.
    let buttonRadius: CGFloat

    // MARK: Pixel

    /// Один физический пиксель в логических единицах.
    var pixel: CGFloat { 1.0 / max(scale, 1) }

    // MARK: - Timer cell helpers

    /// Максимальная ширина ячейки таймера (2-значный label, используется в notch expandedWidth).
    var timerMaxCellWidth: CGFloat {
        timerLeadingInsetWithValue + iconSize + timerIconToValueGap + timerValueWidth + timerTrailingInsetWithValue
    }

    /// Ширина цифровой части таймера для заданного shortLabel.
    func timerDigitsWidth(for shortLabel: String?) -> CGFloat {
        switch shortLabel?.count ?? 0 {
        case 0: return 0
        case 1: return 8
        default: return timerValueWidth
        }
    }

    /// Итоговая ширина ячейки таймера.
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
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            fatalError("No screens available")
        }
        return from(screen: screen)
    }
}

// MARK: - NSScreen + notchGapWidth

extension NSScreen {
    /// Ширина области под нотч в логических пикселях.
    /// Возвращает 0, если нотча нет.
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
