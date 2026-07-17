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
        let hosting = NSHostingView(rootView: FirstLaunchView().managedLocale())
        hosting.sizingOptions = .intrinsicContentSize

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = LocaleManager.shared.string("Welcome to Stampo")
        win.isReleasedWhenClosed = false
        win.contentView = hosting
        win.setContentSize(hosting.intrinsicContentSize)
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
    }

    func close() {
        // Resetting the suppression flag is handled in windowWillClose so it
        // also covers the user closing the window with its title-bar button.
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        UserFacingError.suppressPermissionAlerts = false
        window = nil
    }

    /// Relaunches the app: Screen Recording only takes effect in a fresh
    /// process, so the onboarding offers a one-click restart. A detached shell
    /// waits for this instance to quit, then reopens the bundle.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.4; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

// MARK: - View

struct FirstLaunchView: View {
    private enum Step { case inputMonitoring, screenRecording, downloads, done }

    @State private var launchAtLogin = AppSettings.launchAtLoginEnabled
    @State private var step: Step
    @State private var inputMonitoringGranted: Bool
    @State private var screenRecordingGranted: Bool
    @State private var downloadsGranted = false
    /// The save-folder (Files & Folders) permission has no silent preflight —
    /// probing it fires the prompt — so we only probe after the user asks.
    @State private var downloadsProbeArmed = false
    /// Screen Recording only takes effect in a fresh process — but only matters
    /// when it wasn't already active at launch. A returning user who already
    /// granted it doesn't need a relaunch.
    private let screenRecordingNeededGrant: Bool

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init() {
        let im = CGPreflightListenEventAccess()
        let sr = CGPreflightScreenCaptureAccess()
        _inputMonitoringGranted = State(initialValue: im)
        _screenRecordingGranted = State(initialValue: sr)
        screenRecordingNeededGrant = !sr
        // Start at the first ungranted permission — one at a time, in order.
        // Downloads can't be preflighted silently, so it's always the last gate
        // once the two system permissions are in place.
        _step = State(initialValue: im ? (sr ? .downloads : .screenRecording) : .inputMonitoring)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
                .padding(.bottom, 20)

            notchTip
                .padding(.bottom, 20)

            switch step {
            case .inputMonitoring:
                stepCard(
                    stepLabel: "Step 1 of 3",
                    icon: "keyboard",
                    title: "Keyboard access",
                    description: "Lets you click the notch to open the panel and use global hotkeys. macOS lists this as Input Monitoring.",
                    hint: "Toggle Stampo on in the window macOS opens.",
                    granted: inputMonitoringGranted,
                    grant: {
                        _ = CGRequestListenEventAccess()
                        openSecuritySettings("Privacy_ListenEvent")
                    }
                )
            case .screenRecording:
                stepCard(
                    stepLabel: "Step 2 of 3",
                    icon: "rectangle.dashed.badge.record",
                    title: "Screen recording",
                    description: "Lets Stampo take screenshots and sample colors from the screen.",
                    hint: "Toggle Stampo on in the window macOS opens.",
                    granted: screenRecordingGranted,
                    grant: {
                        _ = CGRequestScreenCaptureAccess()
                        openSecuritySettings("Privacy_ScreenCapture")
                    }
                )
            case .downloads:
                stepCard(
                    stepLabel: "Step 3 of 3",
                    icon: "folder",
                    title: "Save folder access",
                    description: "Lets Stampo save screenshots to your Downloads folder.",
                    hint: "Click Allow in the prompt.",
                    granted: downloadsGranted,
                    grant: {
                        downloadsProbeArmed = true
                        _ = saveFolderAccessible()
                    }
                )
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

    /// Polls the current grants and advances the wizard one permission at a
    /// time — the step flips to the next only once the prior one is granted.
    private func advance() {
        inputMonitoringGranted = CGPreflightListenEventAccess()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        switch step {
        case .inputMonitoring:
            if inputMonitoringGranted {
                step = screenRecordingGranted ? .downloads : .screenRecording
            }
        case .screenRecording:
            if screenRecordingGranted { step = .downloads }
        case .downloads:
            // Only probe (which fires the TCC prompt) after the user asks.
            if downloadsProbeArmed {
                downloadsGranted = saveFolderAccessible()
                if downloadsGranted { step = .done }
            }
        case .done:
            break
        }
    }

    private func openSecuritySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Attempts a read of the save folder inside its security scope. Succeeds
    /// only when the Files & Folders (Downloads) grant is in place; the first
    /// attempt is what surfaces the system prompt.
    private func saveFolderAccessible() -> Bool {
        ((try? AppSettings.withSaveDirectoryAccess { dir -> Bool in
            _ = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            return true
        }) ?? false)
    }

    private func finish(relaunch: Bool) {
        UserDefaults.standard.set(true, forKey: AppSettings.Keys.hasCompletedOnboarding)
        if relaunch {
            FirstLaunchWindowController.relaunch()
        } else {
            FirstLaunchWindowController.shared.close()
        }
    }

    @ViewBuilder
    private func stepCard(
        stepLabel: LocalizedStringKey,
        icon: String,
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        hint: LocalizedStringKey,
        granted: Bool,
        grant: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(stepLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

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
