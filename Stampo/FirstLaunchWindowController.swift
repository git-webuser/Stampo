import SwiftUI
import AppKit
import CoreGraphics
import Combine

// MARK: - Window Controller

final class FirstLaunchWindowController: NSObject {
    static let shared = FirstLaunchWindowController()
    private var window: NSWindow?

    func show() {
        let view = FirstLaunchView()
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = .intrinsicContentSize

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Welcome to Stampo"
        win.isReleasedWhenClosed = false
        win.contentView = hosting
        win.setContentSize(hosting.intrinsicContentSize)
        win.center()
        win.level = .floating
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    func close() {
        window?.close()
        window = nil
    }
}

// MARK: - View

struct FirstLaunchView: View {
    @State private var launchAtLogin          = AppSettings.launchAtLoginEnabled
    @State private var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @State private var inputMonitoringGranted = NotchHoverController.isEventTapInstalled

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
                description: "Required for screenshots and color sampling.",
                granted: screenRecordingGranted,
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )
            .padding(.bottom, 8)

            permissionRow(
                icon: "keyboard",
                title: "Input Monitoring",
                description: "Required for clicking the notch and global hotkeys.",
                granted: inputMonitoringGranted,
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            )
            .padding(.bottom, 20)

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, v in
                    AppSettings.setLaunchAtLogin(v)
                    launchAtLogin = AppSettings.launchAtLoginEnabled
                }
                .padding(.bottom, 24)

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
        .padding(24)
        .frame(width: 420)
        .onReceive(timer) { _ in
            screenRecordingGranted = CGPreflightScreenCaptureAccess()
            inputMonitoringGranted = NotchHoverController.isEventTapInstalled
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchClickStatusChanged)) { _ in
            inputMonitoringGranted = NotchHoverController.isEventTapInstalled
        }
    }

    private var headerSection: some View {
        HStack(spacing: 14) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 64, height: 64)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Stampo")
                    .font(.title2.bold())
                Text("Screenshot and color picker\nfor your MacBook's notch.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var notchTip: some View {
        HStack(spacing: 10) {
            Image(systemName: "cursorarrow.motionlines")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28)
            Text("Hover near the top center of your screen to open the panel.")
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
        settingsURL: String
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
