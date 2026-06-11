import SwiftUI
import AppKit
import CoreGraphics

struct AboutSettingsView: View {
    @State private var didCopyDiagnostics = false

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? v : "\(v) (\(b))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    let icon: NSImage = {
                        // NSApp.applicationIconImage can return a generic placeholder
                        // in debug / non-sandboxed builds. Loading the .icns directly
                        // from the bundle is always reliable.
                        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                           let img = NSImage(contentsOf: url) { return img }
                        return NSApp.applicationIconImage ?? NSImage()
                    }()
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Stampo")
                            .font(.title2.bold())
                        Text("Version \(appVersion)")
                            .foregroundStyle(.secondary)
                        Text("Screenshot & color picker\nfor MacBooks with a notch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
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
                    description: "Paste in a bug report to help diagnose issues."
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
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } header: {
                Text("Diagnostics")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
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
