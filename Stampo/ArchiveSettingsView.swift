import SwiftUI

struct ArchiveSettingsView: View {
    @AppStorage(AppSettings.Keys.trayMaxItems)       private var trayMaxItems       = 20
    @AppStorage(AppSettings.Keys.persistTray)        private var persistTray        = false
    @AppStorage(AppSettings.Keys.defaultColorFormat) private var defaultColorFormat = ColorSchemeType.hex
    @AppStorage(AppSettings.Keys.archiveSpacePreview) private var spacePreview      = true

    var body: some View {
        Form {
            // MARK: History
            Section("History") {
                SettingRow(
                    icon: "archivebox",
                    title: "Maximum items",
                    description: "Older items are removed when the limit is reached — files on disk are not affected"
                ) {
                    // A pop-up rather than a stepper: the range is ten fixed
                    // values, and a stepper made the far end nine clicks on an
                    // arrow a few points tall. It also matches the other rows
                    // in this pane, which are all pop-ups.
                    Picker("Maximum items", selection: $trayMaxItems) {
                        ForEach(Array(stride(from: 5, through: 50, by: 5)), id: \.self) { count in
                            Text(verbatim: "\(count)").tag(count)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }

                SettingRow(icon: "arrow.triangle.2.circlepath", title: "Persist between sessions") {
                    Toggle("", isOn: $persistTray).labelsHidden()
                }
            }

            // MARK: Preview
            Section("Preview") {
                SettingRow(
                    icon: "eye",
                    title: "Preview with Space",
                    description: "Hover an item in the archive and Space opens a preview"
                ) {
                    Toggle("", isOn: $spacePreview).labelsHidden()
                }
            }

            // MARK: Color
            Section("Color") {
                SettingRow(icon: "eyedropper", title: "Default format") {
                    Picker("", selection: $defaultColorFormat) {
                        ForEach(ColorSchemeType.allCases, id: \.self) { fmt in
                            Text(fmt.title).tag(fmt)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }
        }
        .formStyle(.grouped)
    }
}
