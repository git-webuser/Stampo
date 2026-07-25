import SwiftUI
import AppKit
import CoreGraphics

struct GeneralSettingsView: View {
    @AppStorage(AppSettings.Keys.showThumbnailHUD)      private var showThumbnailHUD      = true
    @AppStorage(AppSettings.Keys.thumbnailDismissDelay) private var thumbnailDismissDelay = 3.0
    @AppStorage(AppSettings.Keys.thumbnailClickAction)  private var thumbnailClickAction  = ThumbnailClickAction.editor
    @AppStorage(AppSettings.Keys.settingsAppearance)    private var settingsAppearance     = SettingsAppearance.system
    @AppStorage(AppSettings.Keys.settingsStyle)         private var settingsStyle          = SettingsStyle.toolbar
    @AppStorage(AppSettings.Keys.noNotchPanelStyle)     private var noNotchPanelStyle      = NoNotchPanelStyle.rounded
    @AppStorage(AppSettings.Keys.noNotchNotchScale)     private var noNotchNotchScale      = 1.0
    @AppStorage(AppSettings.Keys.preferredLanguage)     private var preferredLanguage      = "system"

    @State private var launchAtLogin = AppSettings.launchAtLoginEnabled
    @State private var screenRecordingGranted = CGPreflightScreenCaptureAccess()

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
                    icon: "lock.shield",
                    title: "Screen recording",
                    description: "For screenshots, scanning, and color picking"
                ) {
                    HStack(spacing: 12) {
                        Group {
                            if screenRecordingGranted {
                                Text("Granted")
                            } else {
                                Text("Permission required")
                            }
                        }
                        .foregroundStyle(.secondary)

                        Button("Set up…") {
                            openScreenRecordingSettings()
                        }
                    }
                }

                SettingRow(
                    icon: "sparkles",
                    title: "Introduction",
                    description: "Show the welcome again"
                ) {
                    Button("Show…") {
                        FirstLaunchWindowController.shared.show(presentation: .introduction)
                    }
                }
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

                SettingRow(
                    icon: "rectangle.tophalf.inset.filled",
                    title: "Panel shape",
                    description: "On displays without a notch — applies next time the panel opens"
                ) {
                    Picker("", selection: $noNotchPanelStyle) {
                        Text("Pill").tag(NoNotchPanelStyle.rounded)
                        Text("Notch").tag(NoNotchPanelStyle.notch)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                if noNotchPanelStyle == .notch {
                    SettingRow(
                        icon: "arrow.up.left.and.arrow.down.right",
                        title: "Notch panel scale",
                        description: "Fine-tune the size — applies next time the panel opens"
                    ) {
                        Picker("", selection: $noNotchNotchScale) {
                            Text(verbatim: "80%").tag(0.8)
                            Text(verbatim: "90%").tag(0.9)
                            Text(verbatim: "100%").tag(1.0)
                            Text(verbatim: "110%").tag(1.1)
                            Text(verbatim: "120%").tag(1.2)
                            Text(verbatim: "130%").tag(1.3)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
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

                SettingRow(icon: "cursorarrow.click", title: "On thumbnail click") {
                    Picker("", selection: $thumbnailClickAction) {
                        Text("Open editor").tag(ThumbnailClickAction.editor)
                        Text("Open preview").tag(ThumbnailClickAction.preview)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .disabled(!showThumbnailHUD)
                }
            } header: {
                Text("Thumbnail Preview")
            } footer: {
                Text("Click the preview thumbnail to edit or open the screenshot")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshScreenRecordingStatus()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            refreshScreenRecordingStatus()
        }
    }

    private func refreshScreenRecordingStatus() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        // Stampo's settings window floats above normal windows; close it so it
        // cannot cover the System Settings pane the user is trying to change.
        SettingsWindowController.shared.close()
        NSWorkspace.shared.open(url)
    }
}
