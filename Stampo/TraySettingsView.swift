import SwiftUI

struct TraySettingsView: View {
    @AppStorage(AppSettings.Keys.trayMaxItems)       private var trayMaxItems       = 20
    @AppStorage(AppSettings.Keys.persistTray)        private var persistTray        = false
    @AppStorage(AppSettings.Keys.defaultColorFormat) private var defaultColorFormat = ColorSchemeType.hex

    var body: some View {
        Form {
            // MARK: History
            Section {
                SettingRow(icon: "tray.full", title: "Maximum items") {
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
            } header: {
                Text("History")
            } footer: {
                Text("Older items are removed from the tray when the limit is reached. Files on disk are not affected.")
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
