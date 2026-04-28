import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(AppSettings.Keys.showThumbnailHUD)      private var showThumbnailHUD      = true
    @AppStorage(AppSettings.Keys.thumbnailDismissDelay) private var thumbnailDismissDelay = 3.0
    @AppStorage(AppSettings.Keys.settingsAppearance)    private var settingsAppearance     = SettingsAppearance.system
    @AppStorage(AppSettings.Keys.preferredLanguage)     private var preferredLanguage      = "system"

    @State private var launchAtLogin = AppSettings.launchAtLoginEnabled
    @State private var notchClickAvailable = NotchHoverController.isEventTapInstalled

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in
                        AppSettings.setLaunchAtLogin(v)
                        launchAtLogin = AppSettings.launchAtLoginEnabled
                    }

                LabeledContent("Notch click") {
                    if notchClickAvailable {
                        Label("Enabled", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        HStack(spacing: 8) {
                            Button {
                                UserFacingError.present(.notchClickUnavailable)
                            } label: {
                                Label("Permission required", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                            .buttonStyle(.plain)

                            Button("Retry") {
                                NotificationCenter.default.post(name: .retryEventTapInstall, object: nil)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                Button("Permissions Setup…") {
                    FirstLaunchWindowController.shared.show()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .notchClickStatusChanged)) { _ in
                notchClickAvailable = NotchHoverController.isEventTapInstalled
            }

            Section("Appearance") {
                LabeledContent("Settings window theme") {
                    Picker("", selection: $settingsAppearance) {
                        ForEach(SettingsAppearance.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: settingsAppearance) { _, newValue in
                        SettingsWindowController.shared.applyAppearance(newValue)
                    }
                }

                // Language change takes effect immediately via LocaleManager — no restart needed.
                LabeledContent("App language") {
                    Picker("", selection: $preferredLanguage) {
                        Text("System").tag("system")
                        Text("English").tag("en")
                        Text("Русский").tag("ru")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }

            Section {
                Toggle("Show after capture", isOn: $showThumbnailHUD)

                LabeledContent("Auto-dismiss after") {
                    Picker("", selection: $thumbnailDismissDelay) {
                        Text("1 second").tag(1.0)
                        Text("2 seconds").tag(2.0)
                        Text("3 seconds").tag(3.0)
                        Text("5 seconds").tag(5.0)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .disabled(!showThumbnailHUD)
                }
            } header: {
                Text("Thumbnail Preview")
            } footer: {
                Text("Click the preview thumbnail to open the tray.")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
