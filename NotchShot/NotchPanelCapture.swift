import AppKit
import SwiftUI

// MARK: - Capture orchestration

extension NotchPanelController {

    // MARK: Countdown

    /// Screen mode: panel stays open, crossfade to countdown.
    func startScreenCountdown(seconds: Int) {
        countdownCaptureTarget = .screen
        countdownScreen = currentScreen
        rootState.countdownSeconds = seconds
        rootState.countdownTotal = seconds
        route = .cdwn
        withAnimation(.easeOut(duration: 0.16)) {
            rootState.countdownVisible = 1.0
        }
        startCountdownTimer()
    }

    /// Selection/Window mode: hide panel, show pre-selection overlay, then show panel with countdown.
    func launchPreSelection(mode: CaptureMode, seconds: Int) {
        guard !preSelectionInFlight else { return }
        preSelectionInFlight = true
        let screen = currentScreen ?? NSScreen.main ?? NSScreen.screens[0]

        hideAnimated { [weak self] in
            guard let self else { return }
            if mode == .selection {
                self.selectionOverlay.onSelected = { [weak self] rect in
                    guard let self else { return }
                    self.preSelectionInFlight = false
                    self.beginCountdownAfterPreSelection(target: .rect(rect), seconds: seconds, screen: screen)
                }
                self.selectionOverlay.onCancelled = { [weak self] in
                    self?.preSelectionInFlight = false
                }
                self.selectionOverlay.start(on: screen)
            } else {
                // .window
                self.windowPickerOverlay.onSelected = { [weak self] windowID in
                    guard let self else { return }
                    self.preSelectionInFlight = false
                    self.beginCountdownAfterPreSelection(target: .windowID(windowID), seconds: seconds, screen: screen)
                }
                self.windowPickerOverlay.onCancelled = { [weak self] in
                    self?.preSelectionInFlight = false
                }
                self.windowPickerOverlay.start(on: screen)
            }
        }
    }

    /// Called after pre-selection overlay completes: show panel in countdown state directly.
    func beginCountdownAfterPreSelection(target: CaptureTarget, seconds: Int, screen: NSScreen) {
        countdownCaptureTarget = target
        countdownScreen = screen
        rootState.countdownSeconds = seconds
        rootState.countdownTotal = seconds
        // Set countdown visible instantly before panel appears (no crossfade needed)
        rootState.countdownVisible = 1.0
        route = .cdwn
        showAnimated(on: screen)
        startCountdownTimer()
    }

    func startCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.rootState.countdownSeconds > 1 {
                self.rootState.countdownSeconds -= 1
            } else {
                self.finishCountdown()
            }
        }
    }

    func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        route = .main
        withAnimation(.easeOut(duration: 0.16)) {
            rootState.countdownVisible = 0.0
        }
        // Reset arc values only after the fade-out completes,
        // otherwise the arc would jump backwards while still visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.rootState.countdownSeconds = 0
            self?.rootState.countdownTotal = 0
        }
    }

    func captureNowFromCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        let target = countdownCaptureTarget
        let screen = countdownScreen
        hideAnimated { [weak self] in
            self?.executeCapture(target: target, screen: screen)
        }
    }

    func finishCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        let target = countdownCaptureTarget
        let screen = countdownScreen
        hideAnimated { [weak self] in
            self?.executeCapture(target: target, screen: screen)
        }
    }

    func executeCapture(target: CaptureTarget, screen: NSScreen?) {
        switch target {
        case .screen:
            screenshot.capture(mode: .screen, delaySeconds: 0, preferredScreen: screen)
        case .rect(let cgRect):
            screenshot.captureRect(cgRect, preferredScreen: screen)
        case .windowID(let id):
            screenshot.captureWindowID(id, preferredScreen: screen)
        }
    }

    // MARK: Color picker

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
                // Reset route without showing panel
                self.route = .main
                self.rootState.progress = 0.0
            }

            sampler.onCancelled = { [weak self] in
                guard let self else { return }
                self.colorSamplerInFlight = false
                self.activeSampler = nil
                self.colorPickerHUD.hide()
                // Reset route without showing panel
                self.route = .main
                self.rootState.progress = 0.0
            }

            sampler.start()
        }

        if isVisible {
            // Panel is open — hide it first, then launch sampler
            CursorOverlay.hideCursorAfterMenuCloses()
            hideAnimated { launch() }
        } else {
            // Panel already hidden — launch sampler directly, no show/hide cycle
            launch()
        }
    }
}
