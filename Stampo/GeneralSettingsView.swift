import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(AppSettings.Keys.showThumbnailHUD)      private var showThumbnailHUD      = true
    @AppStorage(AppSettings.Keys.thumbnailDismissDelay) private var thumbnailDismissDelay = 3.0
    @AppStorage(AppSettings.Keys.settingsAppearance)    private var settingsAppearance     = SettingsAppearance.system
    @AppStorage(AppSettings.Keys.settingsStyle)         private var settingsStyle          = SettingsStyle.toolbar
    @AppStorage(AppSettings.Keys.preferredLanguage)     private var preferredLanguage      = "system"

    @AppStorage(AppSettings.Keys.checkForUpdates)       private var checkForUpdates       = true

    @State private var launchAtLogin = AppSettings.launchAtLoginEnabled
    @State private var notchClickAvailable = NotchHoverController.isEventTapInstalled
    @State private var updater = UpdateChecker.shared

    var body: some View {
        Form {
            // MARK: Startup
            Section("Startup") {
                SettingRow(icon: "power.circle", title: "Launch at Login") {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .onChange(of: launchAtLogin) { _, v in
                            AppSettings.setLaunchAtLogin(v)
                            launchAtLogin = AppSettings.launchAtLoginEnabled
                        }
                }

                SettingRow(
                    icon: "rectangle.topthird.inset.filled",
                    title: "Notch click",
                    description: "Click the notch area to open the panel"
                ) {
                    if notchClickAvailable {
                        Label("Enabled", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
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

                SettingRow(
                    icon: "lock.shield.fill",
                    title: "Permissions",
                    description: "Screen recording & accessibility"
                ) {
                    Button("Set up…") {
                        FirstLaunchWindowController.shared.show()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .notchClickStatusChanged)) { _ in
                notchClickAvailable = NotchHoverController.isEventTapInstalled
            }

            // MARK: Appearance
            Section("Appearance") {
                SettingRow(icon: "sidebar.left", title: "Settings layout") {
                    SettingsStylePicker(selection: $settingsStyle)
                }
                .onChange(of: settingsStyle) { _, _ in
                    SettingsWindowController.shared.reopenWithNewStyle()
                }

                SettingRow(icon: "circle.lefthalf.filled", title: "Theme") {
                    AppearanceModePicker(selection: $settingsAppearance)
                }
                .onChange(of: settingsAppearance) { _, newValue in
                    SettingsWindowController.shared.applyAppearance(newValue)
                }

                // Language change takes effect immediately via LocaleManager — no restart needed.
                SettingRow(icon: "globe", title: "App language") {
                    Picker("", selection: $preferredLanguage) {
                        Text("System").tag("system")
                        Text("English").tag("en")
                        Text("Русский").tag("ru")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }

            // MARK: Updates
            Section {
                SettingRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Check for updates automatically",
                    description: "Asks GitHub once a day. No other data is sent."
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
                        } else if let date = updater.lastCheckDate {
                            Text(date, style: .relative)
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
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(updater.isChecking)
                    }
                }
            } header: {
                Text("Updates")
            }

            // MARK: Thumbnail Preview
            Section {
                SettingRow(icon: "photo.stack", title: "Show after capture") {
                    Toggle("", isOn: $showThumbnailHUD).labelsHidden()
                }

                SettingRow(icon: "timer", title: "Auto-dismiss after") {
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
