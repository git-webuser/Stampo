import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(AppSettings.Keys.showThumbnailHUD)      private var showThumbnailHUD      = true
    @AppStorage(AppSettings.Keys.thumbnailDismissDelay) private var thumbnailDismissDelay = 3.0
    @AppStorage(AppSettings.Keys.settingsAppearance)    private var settingsAppearance     = SettingsAppearance.system

    @State private var launchAtLogin = AppSettings.launchAtLoginEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in
                        AppSettings.setLaunchAtLogin(v)
                        launchAtLogin = AppSettings.launchAtLoginEnabled
                    }
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
                    .frame(width: 130)
                    .onChange(of: settingsAppearance) { _, newValue in
                        SettingsWindowController.shared.applyAppearance(newValue)
                    }
                }
            }

            Section("Thumbnail Preview") {
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
                    .frame(width: 130)
                    .disabled(!showThumbnailHUD)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
