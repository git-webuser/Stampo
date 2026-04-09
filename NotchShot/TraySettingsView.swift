import SwiftUI

struct TraySettingsView: View {
    @AppStorage(AppSettings.Keys.trayMaxItems)       private var trayMaxItems       = 20
    @AppStorage(AppSettings.Keys.persistTray)        private var persistTray        = false
    @AppStorage(AppSettings.Keys.defaultColorFormat) private var defaultColorFormat = ColorSchemeType.hex

    var body: some View {
        Form {
            Section("History") {
                LabeledContent("Maximum items") {
                    HStack {
                        Stepper(
                            value: $trayMaxItems,
                            in: 5...50,
                            step: 5
                        ) {
                            EmptyView()
                        }
                        .labelsHidden()
                        Text("\(trayMaxItems)")
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                }

                Toggle("Persist between sessions", isOn: $persistTray)
            }

            Section("Color") {
                LabeledContent("Default format") {
                    Picker("", selection: $defaultColorFormat) {
                        ForEach(ColorSchemeType.allCases, id: \.self) { fmt in
                            Text(fmt.title).tag(fmt)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 100)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
