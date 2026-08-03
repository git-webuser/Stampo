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

    @AppStorage(AppSettings.Keys.screenRecordingSetupRequested)
    private var screenRecordingSetupRequested = false

    @State private var launchAtLogin = AppSettings.launchAtLoginEnabled
    @State private var screenRecordingGranted = CGPreflightScreenCaptureAccess()

    /// The user has been to the Privacy pane and the preflight still reads
    /// false — either they haven't flipped the toggle, or they have and this
    /// process can't see it until it restarts. Only the second case is
    /// fixable in-app, and offering the restart costs nothing in the first.
    private var awaitingRelaunch: Bool {
        !screenRecordingGranted && screenRecordingSetupRequested
    }

    private var screenRecordingDescription: LocalizedStringKey {
        awaitingRelaunch
            ? "Turned it on but nothing happened? The permission takes effect after Stampo restarts."
            : "For screenshots, scanning, and color picking"
    }

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
                    description: screenRecordingDescription
                ) {
                    HStack(spacing: 12) {
                        // Redundant next to a Relaunch button: the row's
                        // description already spells that state out in full.
                        if !awaitingRelaunch {
                            Group {
                                if screenRecordingGranted {
                                    Text("Granted")
                                } else {
                                    Text("Permission required")
                                }
                            }
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        }

                        // The grant only registers in a fresh process, so a user
                        // who already toggled Stampo on in System Settings needs
                        // a restart — not another trip to the same pane.
                        if awaitingRelaunch {
                            Button("Relaunch") {
                                FirstLaunchWindowController.relaunch()
                            }
                            .fixedSize()
                        }

                        Button("Set up…") {
                            openScreenRecordingSettings()
                        }
                        .fixedSize()
                    }
                    // Without this the row's description — which grows into a
                    // full sentence while a restart is pending — wins the width
                    // negotiation and the buttons get squeezed to "Rela…".
                    .layoutPriority(1)
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
            Section("Thumbnail Preview") {
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

                SettingRow(
                    icon: "cursorarrow.click",
                    title: "On thumbnail click",
                    description: "Click the preview thumbnail to edit or open the screenshot"
                ) {
                    Picker("", selection: $thumbnailClickAction) {
                        Text("Open editor").tag(ThumbnailClickAction.editor)
                        Text("Open preview").tag(ThumbnailClickAction.preview)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .disabled(!showThumbnailHUD)
                }
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
        // Landed for real: retire the restart prompt so it can't outlive the
        // problem it was offered for.
        if screenRecordingGranted {
            screenRecordingSetupRequested = false
        }
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        screenRecordingSetupRequested = true
        // Stampo's settings window floats above normal windows; close it so it
        // cannot cover the System Settings pane the user is trying to change.
        SettingsWindowController.shared.close()
        NSWorkspace.shared.open(url)
    }
}
