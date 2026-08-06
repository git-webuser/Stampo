import SwiftUI
import AppKit
import CoreGraphics
import Combine

enum FirstLaunchPresentation {
    case onboarding
    case introduction
}

// MARK: - App icon helper

extension NSImage {
    /// NSApp.applicationIconImage can return a generic placeholder in debug /
    /// non-sandboxed builds. Loading the .icns directly from the bundle is
    /// always reliable.
    static var stampoAppIcon: NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) { return img }
        return NSApp.applicationIconImage ?? NSImage()
    }
}

// MARK: - Window Controller

/// Esc closes the wizard, the way the title-bar button already does.
///
/// The usual route — `.keyboardShortcut(.cancelAction)` — has nowhere to go
/// here: the only button on the closing step is the primary one, and it is
/// already spoken for by `.defaultAction`. Taking `cancelOperation` on the
/// window catches Esc wherever focus sits. It belongs on the window rather
/// than the controller below, which is a plain NSObject and so is not in the
/// responder chain at all.
private final class FirstLaunchWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}

final class FirstLaunchWindowController: NSObject, NSWindowDelegate {
    static let shared = FirstLaunchWindowController()
    private var window: NSWindow?

    func show(presentation: FirstLaunchPresentation = .onboarding) {
        // This window is the single permissions surface — mute the standalone
        // modal alerts that would otherwise stack on top of System Settings.
        UserFacingError.suppressPermissionAlerts = true
        // The settings window is `.floating`; close it so the wizard (kept at
        // normal level so it never covers System Settings) isn't opened behind
        // it and left looking like nothing happened.
        SettingsWindowController.shared.close()
        // NSHostingController + contentViewController (not a bare NSHostingView
        // with a one-shot setContentSize): the window then tracks
        // preferredContentSize, so when a step's content grows at runtime —
        // e.g. the Input Monitoring relaunch hint appearing — the window grows
        // with it instead of clipping the bottom padding.
        let hosting = NSHostingController(
            rootView: FirstLaunchView(presentation: presentation).managedLocale()
        )
        hosting.sizingOptions = .preferredContentSize

        let win = FirstLaunchWindow(contentViewController: hosting)
        win.styleMask = [.titled, .closable]
        win.title = LocaleManager.shared.string("Welcome to Stampo")
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(
                    srgbRed: 30.0 / 255.0,
                    green: 30.0 / 255.0,
                    blue: 30.0 / 255.0,
                    alpha: 1
                )
                : .white
        }
        win.isReleasedWhenClosed = false
        // Normal level: the wizard must not sit on top of System Settings while
        // the user toggles a permission there. It auto-advances by polling, so
        // it doesn't need to stay visible during the grant.
        // Keep the window transparent through its first SwiftUI layout pass.
        // Its preferred height is not final until then; revealing it earlier
        // causes a visible jump from AppKit's placeholder origin to the centre.
        win.alphaValue = 0
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        // orderFrontRegardless raises it even when another app (e.g. the one the
        // user launched from) is active, so opening it never looks like a no-op.
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
        // preferredContentSize lands after the first layout pass. Centering
        // before that uses the placeholder size and leaves the finished window
        // shifted toward a corner or partly below the active display.
        DispatchQueue.main.async { [weak self, weak win] in
            guard let self, let win else { return }
            win.contentView?.layoutSubtreeIfNeeded()
            self.centerWindow(win)
            win.alphaValue = 1
        }
        // From here the window's existence (isWindowOpen) is the suppression
        // signal; the stored flag only had to cover the launch→show gap.
        UserFacingError.suppressPermissionAlerts = false
    }

    func close() {
        // Resetting the suppression flag is handled in windowWillClose so it
        // also covers the user closing the window with its title-bar button.
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        UserFacingError.suppressPermissionAlerts = false
        window = nil
        // Let deferred launch work (archive file access) run now that the wizard
        // no longer owns the screen. Fires on every close path — including
        // finishing without the Screen Recording relaunch, where no fresh
        // process would otherwise pick the deferral up.
        NotificationCenter.default.post(name: .onboardingWindowClosed, object: nil)
    }

    func windowDidResize(_ notification: Notification) {
        guard let resizedWindow = notification.object as? NSWindow else { return }
        keepWindowVisible(resizedWindow)
    }

    private func centerWindow(_ window: NSWindow) {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? window.screen
        guard let visibleFrame = targetScreen?.visibleFrame else {
            window.center()
            return
        }

        let frame = window.frame
        let origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2
        )
        window.setFrameOrigin(origin)
        keepWindowVisible(window, within: visibleFrame)
    }

    private func keepWindowVisible(
        _ window: NSWindow,
        within explicitVisibleFrame: NSRect? = nil
    ) {
        guard let visibleFrame = explicitVisibleFrame
            ?? window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        else { return }

        var frame = window.frame
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - frame.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - frame.height)
        frame.origin.x = min(max(frame.minX, visibleFrame.minX), maximumX)
        frame.origin.y = min(max(frame.minY, visibleFrame.minY), maximumY)

        if frame.origin != window.frame.origin {
            window.setFrameOrigin(frame.origin)
        }
    }

    /// Relaunches the app: Screen Recording / Input Monitoring only take
    /// effect in a fresh process, so the onboarding offers a one-click restart.
    /// A detached shell waits for THIS pid to actually exit (bounded at ~10s)
    /// before reopening — a fixed sleep raced a slow teardown, letting `open`
    /// activate the still-dying instance so no new one ever launched.
    @discardableResult
    static func relaunch() -> Bool {
        // Terminating bypasses windowShouldClose, so the editor's own guard
        // would never fire and pending annotations would be lost without a
        // word. Ask first; a cancel calls the whole relaunch off.
        guard EditorWindowController.shared.confirmDiscardingUnsavedWork() else {
            return false
        }

        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c",
            "for i in $(seq 1 100); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
        return true
    }

    /// True while the wizard window exists. UserFacingError uses this as the
    /// primary suppression signal so any dismissal path — delegate callback or
    /// not — automatically stops muting standalone permission alerts.
    var isWindowOpen: Bool { window != nil }
}

extension Notification.Name {
    /// Posted when the onboarding wizard window closes (any path). Consumers
    /// with launch work deferred behind the wizard (e.g. the archive's screenshot
    /// file access) complete it on this signal.
    static let onboardingWindowClosed = Notification.Name("Stampo.onboardingWindowClosed")
}

// MARK: - View

struct FirstLaunchView: View {
    private enum Step { case screenRecording, done }

    private let presentation: FirstLaunchPresentation
    @State private var launchAtLogin = AppSettings.launchAtLoginEnabled
    @State private var step: Step
    @State private var screenRecordingGranted: Bool
    /// True once the user clicked Grant. If they then decline macOS's own
    /// "Quit & Reopen" alert, the preflight can keep reading false in this
    /// process and the step looks stuck — this arms the relaunch card.
    @State private var screenRecordingRequested = false
    /// Reentrancy guard: the done card's auto-relaunch (asyncAfter) and its
    /// button can otherwise both fire finish(), spawning two relaunch shells.
    @State private var didFinish = false
    /// Screen Recording only takes effect in a fresh process — but only matters
    /// when it wasn't already active at launch. A returning user who already
    /// granted it doesn't need a relaunch.
    private let screenRecordingNeededGrant: Bool

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(presentation: FirstLaunchPresentation = .onboarding) {
        self.presentation = presentation
        // Screen Recording is the only system permission left: notch clicks and
        // Esc run on permission-free NSEvent monitors / Carbon hotkeys, and the
        // save folder defaults to ~/Pictures/Stampo (outside the TCC set).
        let sr = CGPreflightScreenCaptureAccess()
        _screenRecordingGranted = State(initialValue: sr)
        screenRecordingNeededGrant = presentation == .onboarding && !sr
        _step = State(
            initialValue: presentation == .introduction || sr ? .done : .screenRecording
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingVideoView()
                .frame(maxWidth: .infinity)

            VStack(spacing: 0) {
                heroSection
                    .padding(.bottom, 18)

                featureList
                    .padding(.bottom, 22)

                switch step {
                case .screenRecording:
                    screenRecordingStep
                case .done:
                    doneCard
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 620)
        // No system prompts fire at launch — the wizard opens each one only
        // when the user acts on that step, so they arrive one at a time.
        .onReceive(timer) { _ in advance() }
    }

    private var heroSection: some View {
        Text("Welcome to Stampo")
            .font(.title.bold())
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    /// What the app does, as left-aligned rows instead of one centred
    /// sentence: a paragraph wraps wherever it happens to fit and splits
    /// phrases mid-thought. Each row is a title over its own description, so
    /// the column reads as three solid blocks rather than a ragged staircase
    /// of one-liners. Glyphs are the ones the app already uses for these
    /// actions, at a weight that holds up next to the body text.
    private var featureList: some View {
        VStack(alignment: .leading, spacing: 16) {
            featureRow(
                "rectangle.dashed",
                "Create and edit screenshots",
                "A selection, a window, or the whole screen. Click the preview to edit."
            )
            featureRow(
                "doc.viewfinder",
                "Scan text and QR codes",
                "Recognized text and links land straight on the clipboard."
            )
            featureRow(
                "arrow.down.document",
                "Manage files",
                "Drag files into the archive by the notch, drop them into any app."
            )
        }
        .frame(width: 400, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func featureRow(
        _ icon: String,
        _ title: LocalizedStringKey,
        _ description: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
    }

    /// Polls the current grant and flips to the done card once it lands.
    private func advance() {
        guard step == .screenRecording else { return }
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        if screenRecordingGranted { step = .done }
    }

    private func openSecuritySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func finish(relaunch: Bool) {
        guard !didFinish else { return }
        didFinish = true
        UserDefaults.standard.set(true, forKey: AppSettings.Keys.hasCompletedOnboarding)
        if relaunch {
            // The relaunch can be called off at the editor's unsaved-changes
            // prompt; re-arm so the button still works on a second press.
            if !FirstLaunchWindowController.relaunch() { didFinish = false }
        } else {
            FirstLaunchWindowController.shared.close()
        }
    }

    private var screenRecordingStep: some View {
        VStack(spacing: 14) {
            Text("Screen recording permission is required.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // macOS places the default action rightmost, with secondary
            // actions to its left.
            HStack(spacing: 12) {
                if screenRecordingRequested {
                    Button {
                        FirstLaunchWindowController.relaunch()
                    } label: {
                        Text("Relaunch")
                            .frame(minWidth: Self.actionLabelMinWidth)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                Button {
                    screenRecordingRequested = true
                    // Also record it where Settings can see it: a user who
                    // grants here but declines macOS's "Quit & Reopen" closes
                    // this window and looks for the restart in Settings.
                    AppSettings.screenRecordingSetupRequested = true
                    _ = CGRequestScreenCaptureAccess()
                    openSecuritySettings("Privacy_ScreenCapture")
                } label: {
                    Text("Open System Settings")
                        .frame(minWidth: Self.actionLabelMinWidth)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }

            // Recovery note, under the actions it explains: it only appears
            // once the user has already been sent to the Privacy pane.
            if screenRecordingRequested {
                Text("Turned it on but nothing happened? The permission takes effect after Stampo restarts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
    }

    /// Shared minimum label width so the Settings and Relaunch buttons render
    /// with the same visual weight.
    private static let actionLabelMinWidth: CGFloat = 150

    private var doneCard: some View {
        VStack(spacing: 14) {
            if screenRecordingNeededGrant {
                Text("Restarting Stampo")
                    .font(.headline)

                Text("Relaunching Stampo to activate screen recording…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 20) {
                Toggle("Launch Stampo at login", isOn: $launchAtLogin)
                    .fixedSize()
                    .onChange(of: launchAtLogin) { _, v in
                        AppSettings.setLaunchAtLogin(v)
                        launchAtLogin = AppSettings.launchAtLoginEnabled
                    }

                Spacer(minLength: 12)

                Button {
                    finish(relaunch: screenRecordingNeededGrant)
                } label: {
                    // Same minimum width as the permission step's buttons, so
                    // the closing action doesn't read as the smallest control
                    // in the flow.
                    Text(actionButtonTitle)
                        .frame(minWidth: Self.actionLabelMinWidth)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: 500)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 500)
        .frame(maxWidth: .infinity)
        .onAppear {
            // The single relaunch at the end, fired automatically when a fresh
            // Screen Recording grant needs a new process to take effect.
            if screenRecordingNeededGrant {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    finish(relaunch: true)
                }
            }
        }
    }

    private var actionButtonTitle: LocalizedStringKey {
        if presentation == .introduction { return "Close" }
        return screenRecordingNeededGrant ? "Relaunch Stampo" : "Get Started"
    }
}
