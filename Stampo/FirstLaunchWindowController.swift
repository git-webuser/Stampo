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
        win.level = .floating
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
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
    @State private var launchAtLogin          = AppSettings.launchAtLoginEnabled
    @State private var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @State private var inputMonitoringGranted = CGPreflightListenEventAccess()

    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
                .padding(.bottom, 20)

            notchTip
                .padding(.bottom, 20)

            Text("Required Permissions")
                .font(.headline)
                .padding(.bottom, 10)

            permissionRow(
                icon: "rectangle.dashed.badge.record",
                title: "Screen Recording",
                description: "Required for screenshots and color sampling",
                granted: screenRecordingGranted,
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                preflight: {
                    // Triggers TCC registration so Stampo appears in
                    // System Settings → Screen & System Audio Recording.
                    _ = CGRequestScreenCaptureAccess()
                }
            )
            .padding(.bottom, 8)

            permissionRow(
                icon: "keyboard",
                title: "Input Monitoring",
                description: "Required for clicking the notch and global hotkeys",
                granted: inputMonitoringGranted,
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
                preflight: {
                    // Registers Stampo in System Settings → Input Monitoring so
                    // the user finds it already listed — without this the entry
                    // never appears and has to be added manually via "+".
                    _ = CGRequestListenEventAccess()
                }
            )
            .padding(.bottom, 20)

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, v in
                    AppSettings.setLaunchAtLogin(v)
                    launchAtLogin = AppSettings.launchAtLoginEnabled
                }
                .padding(.bottom, 24)

            if !screenRecordingGranted || !inputMonitoringGranted {
                Text("Without these permissions, capture, color picking, notch click, and hotkeys may not work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)
            }

            // Screen Recording only activates in a fresh process. Offer a
            // one-click relaunch once it's granted so the user doesn't have to
            // quit and reopen manually.
            if screenRecordingGranted {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise.circle")
                        .foregroundStyle(.blue)
                    Text("Screen Recording activates after a relaunch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Relaunch Stampo") {
                        FirstLaunchWindowController.relaunch()
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.08)))
                .padding(.bottom, 16)
            }

            HStack {
                Spacer()
                Button("Get Started") {
                    UserDefaults.standard.set(true, forKey: AppSettings.Keys.hasCompletedOnboarding)
                    FirstLaunchWindowController.shared.close()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 540)
        .onAppear {
            // Force TCC to register Stampo in *both* privacy lists up front, so
            // each appears already-listed with a prompt instead of needing "+".
            if !CGPreflightScreenCaptureAccess() {
                _ = CGRequestScreenCaptureAccess()
            }
            if !CGPreflightListenEventAccess() {
                _ = CGRequestListenEventAccess()
            }
        }
        .onReceive(timer) { _ in
            screenRecordingGranted = CGPreflightScreenCaptureAccess()
            inputMonitoringGranted = CGPreflightListenEventAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchClickStatusChanged)) { _ in
            inputMonitoringGranted = CGPreflightListenEventAccess()
        }
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

    @ViewBuilder
    private func permissionRow(
        icon: String,
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        granted: Bool,
        settingsURL: String,
        preflight: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(granted ? .green : .orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).fontWeight(.medium)
                    Spacer()
                    if granted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Button("Open System Settings") {
                            preflight?()
                            if let url = URL(string: settingsURL) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}
