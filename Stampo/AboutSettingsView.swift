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
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    }
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
                Link("View on GitHub",
                     destination: URL(string: "https://github.com/git-webuser/Stampo")!)
                Link("Report an Issue",
                     destination: URL(string: "https://github.com/git-webuser/Stampo/issues")!)
            }

            Section {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnosticsString(), forType: .string)
                    withAnimation { didCopyDiagnostics = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { didCopyDiagnostics = false }
                    }
                } label: {
                    Label(
                        didCopyDiagnostics ? "Copied!" : "Copy Diagnostics",
                        systemImage: didCopyDiagnostics ? "checkmark" : "doc.on.clipboard"
                    )
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Paste in a bug report to help diagnose issues.")
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
        """
    }
}
