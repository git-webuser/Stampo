import AppKit

// MARK: - ColorPickingCoordinator

/// Owns the ColorSampler + ColorPickerHUD lifecycle.
/// NotchPanelController holds one instance and wires callbacks in init().
final class ColorPickingCoordinator {
    private(set) var isInFlight: Bool = false
    private var activeSampler: ColorSampler?
    private let hud = ColorPickerHUD()

    // Callbacks wired by the owner
    var hidePanel: (@escaping () -> Void) -> Void = { $0() }
    var addColor: (NSColor) -> Void = { _ in }
    var resetRoute: () -> Void = {}
    var hideCursorBeforeHide: () -> Void = {}

    /// Прерывает активную сессию выбора цвета без уведомления через колбэки.
    /// Вызывается из invalidatePanelAfterEnvironmentChange, когда среда меняется
    /// до завершения пользователем действия (sleep, display change и т. д.).
    @MainActor
    func cancel() {
        guard isInFlight else { return }
        activeSampler?.cancel()
        activeSampler = nil
        hud.hide(animated: false)
        isInFlight = false
        // resetRoute не вызываем — панель уже сносится вызывающей стороной.
    }

    @MainActor
    func start(panelIsVisible: Bool, preferredScreen: NSScreen?) {
        guard !isInFlight else { return }
        isInFlight = true

        let launch: () -> Void = { [weak self] in
            guard let self else { return }
            let sampler = ColorSampler()
            self.activeSampler = sampler
            self.hud.beginSession(format: sampler.format)

            sampler.onColorChanged = { [weak self] color, position, magnifier in
                guard let self else { return }
                self.hud.setFormat(sampler.format)
                self.hud.update(color: color, cursorPosition: position, magnifier: magnifier)
            }

            sampler.onConfirmed = { [weak self] color in
                guard let self else { return }
                self.isInFlight = false
                self.activeSampler = nil
                let sRGB = color.usingColorSpace(.sRGB) ?? color
                self.hud.showSuccess(color: sRGB, on: preferredScreen, autoHideAfter: 0.35)
                let formatted = self.hud.currentFormat.format(sRGB)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(formatted, forType: .string)
                self.addColor(sRGB)
                self.resetRoute()
            }

            sampler.onCancelled = { [weak self] in
                guard let self else { return }
                self.isInFlight = false
                self.activeSampler = nil
                self.hud.hide()
                self.resetRoute()
            }

            sampler.start()
        }

        if panelIsVisible {
            hideCursorBeforeHide()
            hidePanel { launch() }
        } else {
            launch()
        }
    }
}

// MARK: - Color picker orchestration

extension NotchPanelController {

    @MainActor
    func pickColor() {
        let screen = currentScreen ?? NSScreen.main
        colorPicker.start(panelIsVisible: isVisible, preferredScreen: screen)
    }
}
