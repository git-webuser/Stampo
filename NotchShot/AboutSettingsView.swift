import SwiftUI

struct AboutSettingsView: View {
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
                        Text("NotchShot")
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
                     destination: URL(string: "https://github.com/git-webuser/NotchShot")!)
                Link("Report an Issue",
                     destination: URL(string: "https://github.com/git-webuser/NotchShot/issues")!)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
