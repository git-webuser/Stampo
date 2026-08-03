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
                    HStack {
                        Stepper(value: $trayMaxItems, in: 5...50, step: 5) { EmptyView() }
                            .labelsHidden()
                        Text("\(trayMaxItems)")
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
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
