import SwiftUI
import AppKit
import CoreGraphics
import Combine

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

final class FirstLaunchWindowController: NSObject, NSWindowDelegate {
    static let shared = FirstLaunchWindowController()
    private var window: NSWindow?

    func show() {
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
        let hosting = NSHostingController(rootView: FirstLaunchView().managedLocale())
        hosting.sizingOptions = .preferredContentSize

        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.titled, .closable]
        win.title = LocaleManager.shared.string("Welcome to Stampo")
        win.isReleasedWhenClosed = false
        win.center()
        // Normal level: the wizard must not sit on top of System Settings while
        // the user toggles a permission there. It auto-advances by polling, so
        // it doesn't need to stay visible during the grant.
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        // orderFrontRegardless raises it even when another app (e.g. the one the
        // user launched from) is active, so opening it never looks like a no-op.
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
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
        // Let deferred launch work (tray file access) run now that the wizard
        // no longer owns the screen. Fires on every close path — including
        // finishing without the Screen Recording relaunch, where no fresh
        // process would otherwise pick the deferral up.
        NotificationCenter.default.post(name: .onboardingWindowClosed, object: nil)
    }

    /// Relaunches the app: Screen Recording / Input Monitoring only take
    /// effect in a fresh process, so the onboarding offers a one-click restart.
    /// A detached shell waits for THIS pid to actually exit (bounded at ~10s)
    /// before reopening — a fixed sleep raced a slow teardown, letting `open`
    /// activate the still-dying instance so no new one ever launched.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c",
            "for i in $(seq 1 100); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// True while the wizard window exists. UserFacingError uses this as the
    /// primary suppression signal so any dismissal path — delegate callback or
    /// not — automatically stops muting standalone permission alerts.
    var isWindowOpen: Bool { window != nil }
}

extension Notification.Name {
    /// Posted when the onboarding wizard window closes (any path). Consumers
    /// with launch work deferred behind the wizard (e.g. the tray's screenshot
    /// file access) complete it on this signal.
    static let onboardingWindowClosed = Notification.Name("Stampo.onboardingWindowClosed")
}

// MARK: - View

struct FirstLaunchView: View {
    private enum Step { case screenRecording, done }

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

    init() {
        // Screen Recording is the only system permission left: notch clicks and
        // Esc run on permission-free NSEvent monitors / Carbon hotkeys, and the
        // save folder defaults to ~/Pictures/Stampo (outside the TCC set).
        let sr = CGPreflightScreenCaptureAccess()
        _screenRecordingGranted = State(initialValue: sr)
        screenRecordingNeededGrant = !sr
        _step = State(initialValue: sr ? .done : .screenRecording)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
                .padding(.bottom, 20)

            notchTip
                .padding(.bottom, 20)

            switch step {
            case .screenRecording:
                stepCard(
                    icon: "rectangle.dashed.badge.record",
                    title: "Screen recording",
                    description: "Lets Stampo take screenshots and sample colors from the screen.",
                    hint: "Toggle Stampo on in the window macOS opens.",
                    granted: screenRecordingGranted,
                    grant: {
                        screenRecordingRequested = true
                        _ = CGRequestScreenCaptureAccess()
                        openSecuritySettings("Privacy_ScreenCapture")
                    }
                )
                // The grant may only register in a fresh process: if the user
                // declined macOS's "Quit & Reopen" alert, the toggle is on but
                // the step can't advance — a separate card offers the relaunch.
                if screenRecordingRequested && !screenRecordingGranted {
                    relaunchCard
                        .padding(.top, 12)
                }
            case .done:
                doneCard
            }
        }
        .padding(28)
        .frame(width: 540)
        // No system prompts fire at launch — the wizard opens each one only
        // when the user acts on that step, so they arrive one at a time.
        .onReceive(timer) { _ in advance() }
    }

    private var headerSection: some View {
        HStack(spacing: 14) {
            Image(nsImage: .stampoAppIcon)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Stampo")
                    .font(.title2.bold())
                Text("Screenshot and color picker\nthat lives in your menu bar.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var notchTip: some View {
        HStack(spacing: 10) {
            Image(systemName: "cursorarrow.click")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28)
            Text("Click the notch — or the center of the menu bar on screens without one — to open the panel.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.08)))
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
            FirstLaunchWindowController.relaunch()
        } else {
            FirstLaunchWindowController.shared.close()
        }
    }

    @ViewBuilder
    private func stepCard(
        icon: String,
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        hint: LocalizedStringKey,
        granted: Bool,
        grant: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(granted ? .green : .blue)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if granted {
                Label("Granted — continuing…", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                HStack(spacing: 10) {
                    Button("Grant Access", action: grant)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    /// Companion card under the permission step: the grant may only take
    /// effect in a fresh process, so after the user acted in System Settings
    /// this offers the restart macOS's own alert may have been declined for.
    private var relaunchCard: some View {
        HStack(spacing: 10) {
            Button("Relaunch Stampo") {
                FirstLaunchWindowController.relaunch()
            }
            // Secondary: Grant is the step's one primary action; this is the
            // recovery path, not competing for attention.
            .buttonStyle(.bordered)
            .controlSize(.large)
            Text("Turned it on but nothing happened? The permission takes effect after Stampo restarts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private var doneCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("All set").font(.headline)
                    Text(screenRecordingNeededGrant
                         ? "Relaunching Stampo to activate screen recording…"
                         : "Permissions granted. You're ready to go.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, v in
                    AppSettings.setLaunchAtLogin(v)
                    launchAtLogin = AppSettings.launchAtLoginEnabled
                }

            HStack {
                Spacer()
                Button(screenRecordingNeededGrant ? "Relaunch Stampo" : "Get Started") {
                    finish(relaunch: screenRecordingNeededGrant)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.08)))
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
}
