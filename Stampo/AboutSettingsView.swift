import SwiftUI
import AppKit
import CoreGraphics

struct AboutSettingsView: View {
    @AppStorage(AppSettings.Keys.checkForUpdates) private var checkForUpdates = true
    @State private var didCopyDiagnostics = false
    @State private var updater = UpdateChecker.shared

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? v : "\(v) (\(b))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: .stampoAppIcon)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Stampo")
                            .font(.title2.bold())
                        Text("Version \(appVersion)")
                            .foregroundStyle(.secondary)
                        Text("Screenshot & color picker for any Mac")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // MARK: Updates
            Section("Updates") {
                SettingRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Check for updates automatically",
                    description: "Asks GitHub once a day. No other data is sent"
                ) {
                    Toggle("", isOn: $checkForUpdates).labelsHidden()
                }

                SettingRow(icon: "clock", title: "Last checked") {
                    HStack(spacing: 8) {
                        if let version = updater.availableVersion {
                            Link(destination: UpdateChecker.releasesPageURL) {
                                Text("Version \(version) available")
                                    .font(.callout)
                            }
                        } else if let lastCheck = updater.lastCheckDescription {
                            Text(lastCheck)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Never")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Button("Check Now") {
                            Task { await updater.check(userInitiated: true) }
                        }
                        .disabled(updater.isChecking)
                    }
                }
            }

            Section("Links") {
                SettingRow(icon: "chevron.left.forwardslash.chevron.right", title: "View on GitHub") {
                    Link(destination: URL(string: "https://github.com/git-webuser/Stampo")!) {
                        Image(systemName: "arrow.up.right.square")
                    }
                }
                SettingRow(icon: "exclamationmark.bubble", title: "Report an Issue") {
                    Link(destination: URL(string: "https://github.com/git-webuser/Stampo/issues")!) {
                        Image(systemName: "arrow.up.right.square")
                    }
                }
            }

            Section {
                SettingRow(
                    icon: "stethoscope",
                    title: "Copy Diagnostics",
                    description: "Paste in a bug report to help diagnose issues"
                ) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnosticsString(), forType: .string)
                        withAnimation { didCopyDiagnostics = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { didCopyDiagnostics = false }
                        }
                    } label: {
                        Label(
                            didCopyDiagnostics ? "Copied!" : "Copy",
                            systemImage: didCopyDiagnostics ? "checkmark" : "doc.on.clipboard"
                        )
                    }
                }
            } header: {
                Text("Diagnostics")
            }
        }
        .formStyle(.grouped)
    }

    private func diagnosticsString() -> String {
        let version = appVersion
        let macOS = ProcessInfo.processInfo.operatingSystemVersionString

        let screenCount = NSScreen.screens.count
        let mainFrame = NSScreen.main.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" } ?? "unknown"
        let notchGap: String
        if let main = NSScreen.main {
            let gap = main.notchGapWidth
            notchGap = gap > 0 ? "\(Int(gap))pt" : "none"
        } else {
            notchGap = "unknown"
        }

        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        let screenRecording = CGPreflightScreenCaptureAccess() ? "granted" : "denied"
        let inputMonitoring = NotchHoverController.isEventTapInstalled ? "granted" : "denied"

        let saveDir: String
        let url = AppSettings.saveDirectoryURL
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        saveDir = url.path.replacingOccurrences(of: home, with: "~")

        let trayMax = UserDefaults.standard.object(forKey: AppSettings.Keys.trayMaxItems) as? Int ?? 20
        let trayPersist = UserDefaults.standard.object(forKey: AppSettings.Keys.persistTray) as? Bool ?? true

        let trace = DebugTrace.dump()

        return """
        Stampo \(version)
        macOS \(macOS)
        App Sandbox: \(sandboxed ? "on" : "off")
        Hardened Runtime: on
        Screens: \(screenCount) (\(mainFrame))
        Notch gap: \(notchGap)
        Screen Recording: \(screenRecording)
        Input Monitoring: \(inputMonitoring)
        Save directory: \(saveDir)
        Tray persist: \(trayPersist ? "on" : "off"), max \(trayMax) items

        --- Panel Trace ---
        \(trace)
        """
    }
}
