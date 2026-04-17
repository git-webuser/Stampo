import AppKit
import SwiftUI

// MARK: - Color picker orchestration

extension NotchPanelController {

    /// Launch the color-picker sampler.
    /// Hides the panel first if it is open, then starts `ColorSampler` and
    /// wires up the `ColorPickerHUD` for live feedback. On confirmation the
    /// color is copied to the clipboard and added to the tray.
    @MainActor
    func pickColor() {
        guard !colorSamplerInFlight else { return }
        colorSamplerInFlight = true

        let screen = currentScreen ?? NSScreen.main

        let launch = { [weak self] in
            guard let self else { return }

            let sampler = ColorSampler()
            self.activeSampler = sampler
            self.colorPickerHUD.beginSession(format: sampler.format)

            sampler.onColorChanged = { [weak self] color, position, magnifier in
                guard let self else { return }
                self.colorPickerHUD.setFormat(sampler.format)
                self.colorPickerHUD.update(color: color, cursorPosition: position, magnifier: magnifier)
            }

            sampler.onConfirmed = { [weak self] color in
                guard let self else { return }
                self.colorSamplerInFlight = false
                self.activeSampler = nil

                let sRGB = color.usingColorSpace(.sRGB) ?? color
                self.colorPickerHUD.showSuccess(color: sRGB, on: screen, autoHideAfter: 0.35)

                let formatted = self.colorPickerHUD.currentFormat.format(sRGB)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(formatted, forType: .string)

                self.trayModel.add(color: sRGB)
                // Reset route without re-showing the panel.
                self.route = .main
                self.rootState.progress = 0.0
            }

            sampler.onCancelled = { [weak self] in
                guard let self else { return }
                self.colorSamplerInFlight = false
                self.activeSampler = nil
                self.colorPickerHUD.hide()
                // Reset route without re-showing the panel.
                self.route = .main
                self.rootState.progress = 0.0
            }

            sampler.start()
        }

        if isVisible {
            // Panel is open — hide it first, then launch the sampler.
            CursorOverlay.hideCursorAfterMenuCloses()
            hideAnimated { launch() }
        } else {
            // Panel already hidden — launch the sampler directly.
            launch()
        }
    }
}
