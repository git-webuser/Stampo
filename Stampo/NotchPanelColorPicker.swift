import AppKit

// MARK: - ColorPickingCoordinator

/// Owns the ColorSampler + ColorPickerHUD lifecycle.
/// NotchPanelController holds one instance and wires callbacks in init().
final class ColorPickingCoordinator {
    private(set) var isInFlight: Bool = false
    private(set) var activeSampler: ColorSampler?
    private let hud = ColorPickerHUD()

    // Callbacks wired by the owner
    var hidePanel: (@escaping () -> Void) -> Void = { $0() }
    var addColor: (NSColor) -> Void = { _ in }
    var resetRoute: () -> Void = {}
    var hideCursorBeforeHide: () -> Void = {}
    var onFlightChanged: ((Bool) -> Void)?
    var onCursorMoved:  ((NSPoint) -> Void)?
    /// Called when the user successfully picks a color (confirmed, not cancelled).
    /// Use this to trigger a celebration state instead of going straight to sleeping.
    var onPickConfirmed: (() -> Void)?

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
        onFlightChanged?(false)
        // resetRoute не вызываем — панель уже сносится вызывающей стороной.
    }

    @MainActor
    func start(panelIsVisible: Bool, preferredScreen: NSScreen?) {
        guard !isInFlight else { return }
        isInFlight = true
        onFlightChanged?(true)

        let launch: () -> Void = { [weak self] in
            guard let self else { return }
            let sampler = ColorSampler()
            self.hud.beginSession(format: sampler.format)
            self.attach(sampler, preferredScreen: preferredScreen)
            sampler.start()
        }

        if panelIsVisible {
            hideCursorBeforeHide()
            hidePanel { launch() }
        } else {
            launch()
        }
    }

    /// Makes `sampler` the active one and connects its callbacks to this
    /// coordinator. Split out of `start` so a test can check what keeps the
    /// sampler alive without a real capture.
    func attach(_ sampler: ColorSampler, preferredScreen: NSScreen?) {
        activeSampler = sampler
        // `sampler` stays weak: the sampler stores this closure, so a strong
        // capture is a retain cycle that keeps it, its overlay and the overlay's
        // full-screen window alive after every pick.
        sampler.onColorChanged = { [weak self, weak sampler] color, position, magnifier in
            guard let self, let sampler else { return }
            self.hud.setFormat(sampler.format)
            self.hud.update(color: color, cursorPosition: position, magnifier: magnifier)
            self.onCursorMoved?(position)
        }

        sampler.onConfirmed = { [weak self] color in
            guard let self else { return }
            self.isInFlight = false
            // Do NOT call onFlightChanged(false) here — that would post .sleeping
            // and cancel the celebration sequence before the wink plays.
            // onPickConfirmed triggers .celebrating; the sequence itself ends with .sleeping.
            self.onPickConfirmed?()
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
            self.onFlightChanged?(false)
            self.activeSampler = nil
            self.hud.hide()
            self.resetRoute()
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
