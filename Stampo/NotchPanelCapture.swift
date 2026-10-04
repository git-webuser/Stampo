import AppKit
import SwiftUI

// MARK: - Countdown session

/// Bundles every piece of countdown state into a single value so the
/// controller no longer has to juggle parallel fields (`countdownTimer`,
/// `countdownCaptureTarget`, `countdownScreen`).
struct CountdownSession {
    let target: NotchPanelController.CaptureTarget
    let screen: NSScreen?
    var secondsRemaining: Int
    let totalSeconds: Int
    var timer: Timer?
}

// MARK: - Capture orchestration

extension NotchPanelController {

    // MARK: Countdown

    /// Mirrors the authoritative `activeCountdown` into the view-facing
    /// `rootState` fields so the SwiftUI countdown arc updates without
    /// reading the session struct directly.
    private func syncCountdownToRootState() {
        rootState.countdownSeconds = activeCountdown?.secondsRemaining ?? 0
        rootState.countdownTotal   = activeCountdown?.totalSeconds   ?? 0
    }

    /// Screen mode: panel stays open, crossfade to countdown.
    func startScreenCountdown(seconds: Int) {
        activeCountdown = CountdownSession(
            target: .screen,
            screen: currentScreen,
            secondsRemaining: seconds,
            totalSeconds: seconds,
            timer: nil
        )
        syncCountdownToRootState()
        rootState.scrollStrip = nil
        state = .countdown
        route = .cdwn
        withAnimation(.easeOut(duration: 0.16)) {
            rootState.countdownVisible = 1.0
        }
        startCountdownTimer()
    }

    /// Selection/Window mode: hide panel, show pre-selection overlay, then show panel with countdown.
    func launchPreSelection(mode: CaptureMode, seconds: Int) {
        guard !isInPreSelection else { return }
        // Fail closed if there's no screen to present the overlay on (headless
        // Mac or mid-reconfiguration). Previously this forced `screens[0]` and
        // crashed on empty screens.
        guard let screen = currentScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        hideAnimated(reason: .captureStart) { [weak self] in
            guard let self else { return }
            // hideAnimated set state to .hidden; promote to .preSelection now
            // that the overlay is taking over the visible UI.
            let kind: OverlayKind = (mode == .selection) ? .selection : .window
            self.state = .preSelection(kind)
            let selectionToken = self.makePanelTransitionToken()
            if mode == .selection {
                self.selectionOverlay.onSelected = { [weak self] rect in
                    guard let self else { return }
                    guard self.animationGenerationMatches(selectionToken),
                          case .preSelection(.selection) = self.state
                    else { return }
                    // beginCountdownAfterPreSelection sets state = .countdown.
                    self.state = .hidden
                    self.schedulePanelAction(after: 0.1,
                                             token: selectionToken,
                                             requiresVisible: false) { [weak self] in
                        guard let self, case .hidden = self.state else { return }
                        self.beginCountdownAfterPreSelection(target: .rect(rect),
                                                             seconds: seconds,
                                                             screen: screen)
                    }
                }
                self.selectionOverlay.onCancelled = { [weak self] in
                    guard let self,
                          self.animationGenerationMatches(selectionToken) else { return }
                    self.invalidatePanelTransitionActions()
                    self.state = .hidden
                }
                self.selectionOverlay.start(on: screen)
            } else {
                // .window
                self.windowPickerOverlay.onSelectedWindow = nil
                self.windowPickerOverlay.badge = nil
                self.windowPickerOverlay.onSelected = { [weak self] windowID in
                    guard let self else { return }
                    guard self.animationGenerationMatches(selectionToken),
                          case .preSelection(.window) = self.state
                    else { return }
                    self.beginCountdownAfterPreSelection(target: .windowID(windowID), seconds: seconds, screen: screen)
                }
                if let axis = mode.scrollAxis {
                    // The picker is the same one an ordinary Window shot uses;
                    // only here is the click not obviously "this window".
                    self.windowPickerOverlay.badge = ScanModeBadge(
                        title: LocaleManager.shared.string("Click the area to scroll"),
                        symbolName: mode.icon)
                    self.windowPickerOverlay.onSelected = nil
                    self.windowPickerOverlay.onSelectedWindow = { [weak self] selection in
                        guard let self else { return }
                        guard self.animationGenerationMatches(selectionToken),
                              case .preSelection(.window) = self.state else { return }
                        // The strip goes where the window is, which need not be
                        // the screen the picker was on.
                        let windowCenter = CGPoint(x: selection.bounds.midX, y: selection.bounds.midY)
                        let stripScreen = NSScreen.containing(quartzPoint: windowCenter) ?? screen
                        if seconds > 0 {
                            // The countdown turns into the strip in place when it ends.
                            self.beginCountdownAfterPreSelection(target: .scrolling(selection, axis),
                                                                 seconds: seconds, screen: stripScreen)
                        } else {
                            self.beginScrollCapture(selection: selection, axis: axis, screen: stripScreen)
                        }
                    }
                }
                self.windowPickerOverlay.onCancelled = { [weak self] in
                    guard let self,
                          self.animationGenerationMatches(selectionToken) else { return }
                    self.invalidatePanelTransitionActions()
                    self.state = .hidden
                }
                self.windowPickerOverlay.start(on: screen)
            }
        }
    }

    /// Called after pre-selection overlay completes: show panel in countdown state directly.
    func beginCountdownAfterPreSelection(target: CaptureTarget, seconds: Int, screen: NSScreen) {
        activeCountdown = CountdownSession(
            target: target,
            screen: screen,
            secondsRemaining: seconds,
            totalSeconds: seconds,
            timer: nil
        )
        syncCountdownToRootState()
        rootState.scrollStrip = nil
        // Set countdown visible instantly before panel appears (no crossfade needed)
        rootState.countdownVisible = 1.0
        route = .cdwn
        showAnimated(on: screen)
        // showAnimated's completion only finalises to .main when state is still
        // .showing, so this assignment survives the animation completing.
        state = .countdown
        startCountdownTimer()
    }

    func startCountdownTimer() {
        cancelCountdownTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleCountdownTick()
            }
        }
        activeCountdown?.timer = timer
    }

    private func handleCountdownTick() {
        guard var session = activeCountdown else { return }
        if session.secondsRemaining > 1 {
            session.secondsRemaining -= 1
            activeCountdown = session
            syncCountdownToRootState()
        } else {
            finishCountdown()
        }
    }

    /// Single authoritative place to kill the countdown Timer.
    /// Called from every exit path (stop / capture-now / finish / hideAnimated /
    /// deinit) so the tick closure can never fire into a freed controller.
    func cancelCountdownTimer() {
        activeCountdown?.timer?.invalidate()
        activeCountdown?.timer = nil
    }

    func stopCountdown() {
        cancelCountdownTimer()
        activeCountdown = nil
        state = .main
        route = .main
        let token = makePanelTransitionToken()
        withAnimation(.easeOut(duration: 0.16)) {
            rootState.countdownVisible = 0.0
        }
        // Reset arc values only after the fade-out completes,
        // otherwise the arc would jump backwards while still visible.
        schedulePanelAction(after: 0.18, token: token) { [weak self] in
            self?.rootState.countdownSeconds = 0
            self?.rootState.countdownTotal = 0
        }
    }

    func captureNowFromCountdown() {
        finishCountdown()
    }

    func finishCountdown() {
        cancelCountdownTimer()
        let target = activeCountdown?.target ?? .screen
        let screen = activeCountdown?.screen
        activeCountdown = nil
        // Scrolling does not hide the panel to capture: the countdown strip
        // stays and its arc turns into the ring.
        if case .scrolling(let selection, let axis) = target {
            beginScrollCapture(selection: selection, axis: axis, screen: screen)
            return
        }
        hideAnimated(reason: .captureStart) { [weak self] in
            guard let self else { return }
            // Safety net: if the window-picker dismissed normally, isCursorHidden
            // is already false and this is a no-op. Guards against any edge case
            // where dismiss() was skipped.
            self.windowPickerOverlay.resetCursorState()
            self.executeCapture(target: target, screen: screen)
        }
    }

    // MARK: Scrolling capture

    /// ✕ on the strip: stops the countdown, or drops the scrolling capture.
    func stopFromStrip() {
        if case .scrollCapture = state {
            screenshot.cancelScrolling()
        } else {
            stopCountdown()
        }
    }

    /// The capture button on the strip: captures now, or — once a scrolling
    /// capture is running — says it is done and saves what is collected.
    func captureFromStrip() {
        if case .scrollCapture = state {
            screenshot.finishScrolling()
        } else {
            captureNowFromCountdown()
        }
    }

    /// Puts the strip up with the ring turning and starts the capture. From a
    /// countdown that ran out the panel is already there and nothing moves
    /// but the arc; with no delay it arrives the way the countdown does.
    func beginScrollCapture(selection: WindowPickerSelection, axis: ScrollAxis, screen: NSScreen?) {
        windowPickerOverlay.resetCursorState()
        rootState.scrollStrip = .running
        if case .countdown = state {
            state = .scrollCapture
        } else {
            guard let screen = screen ?? currentScreen ?? NSScreen.main ?? NSScreen.screens.first else {
                // Nowhere to put the strip: leave the picker's state behind,
                // or the next capture would find a selection still in flight.
                rootState.scrollStrip = nil
                state = .hidden
                return
            }
            rootState.countdownVisible = 1.0
            route = .cdwn
            showAnimated(on: screen)
            // As for the countdown: showAnimated's completion only settles
            // `.showing` into `.main`, so this assignment survives it.
            state = .scrollCapture
        }
        // Another capture may already be running; the strip must not stay up
        // for a session that never started.
        if !screenshot.captureScrolling(selection: selection, axis: axis, preferredScreen: currentScreen) {
            hideAnimated(reason: .scrollCaptureEnded)
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
        case .scrolling(let selection, let axis):
            // Not reached from the countdown, which keeps its panel; kept so
            // the switch stays total and a direct call still does the right thing.
            beginScrollCapture(selection: selection, axis: axis, screen: screen)
        }
    }
}
