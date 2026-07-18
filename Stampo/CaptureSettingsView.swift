import SwiftUI
import AppKit

struct CaptureSettingsView: View {
    @AppStorage(AppSettings.Keys.saveDirectory)       private var saveDirectory       = ""
    @AppStorage(AppSettings.Keys.fileFormat)          private var fileFormat          = "png"
    @AppStorage(AppSettings.Keys.filenamePreset)      private var filenamePreset      = FilenamePreset.compact.rawValue
    @AppStorage(AppSettings.Keys.playSound)           private var playSound           = true
    @AppStorage(AppSettings.Keys.copyToClipboard)     private var copyToClipboard     = true
    @AppStorage(AppSettings.Keys.includeCursor)       private var includeCursor       = false
    @AppStorage(AppSettings.Keys.includeWindowShadow) private var includeWindowShadow = true
    @AppStorage(AppSettings.Keys.defaultCaptureMode)  private var defaultCaptureMode  = CaptureMode.selection
    @AppStorage(AppSettings.Keys.defaultTimerDelay)   private var defaultTimerDelay   = CaptureDelay.off

    private var saveFolderDisplay: String {
        // Empty == the ~/Pictures/Stampo default (see AppSettings.defaultSaveURL).
        saveDirectory.isEmpty
            ? "Stampo"
            : URL(fileURLWithPath: saveDirectory).lastPathComponent
    }

    private var selectedPreset: FilenamePreset {
        FilenamePreset(rawValue: filenamePreset) ?? .compact
    }

    private var filenamePreview: String {
        AppSettings.resolveFilename(
            preset: selectedPreset,
            date: Date(),
            counter: AppSettings.captureCounter + 1,
            format: fileFormat
        )
    }

    var body: some View {
        Form {
            // MARK: File
            Section("File") {
                SettingRow(icon: "folder", title: "Save to") {
                    HStack(spacing: 6) {
                        Text(saveFolderDisplay)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseSaveFolder() }
                    }
                }

                SettingRow(icon: "photo", title: "Format") {
                    Picker("", selection: $fileFormat) {
                        Text("PNG").tag("png")
                        Text("JPEG").tag("jpg")
                        Text("TIFF").tag("tiff")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }

            // MARK: Filename
            Section {
                SettingRow(icon: "textformat", title: "Style") {
                    Picker("", selection: $filenamePreset) {
                        ForEach(FilenamePreset.allCases, id: \.rawValue) { preset in
                            Text(LocalizedStringKey(preset.name)).tag(preset.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            } header: {
                Text("Filename")
            } footer: {
                // macOS-style helper caption showing the live result.
                Text("Saved as \(filenamePreview)")
            }

            // MARK: Behavior
            Section("Behavior") {
                SettingRow(icon: "speaker.wave.2", title: "Play sound") {
                    Toggle("", isOn: $playSound).labelsHidden()
                }
                SettingRow(icon: "doc.on.clipboard", title: "Copy to clipboard") {
                    Toggle("", isOn: $copyToClipboard).labelsHidden()
                }
                SettingRow(icon: "cursorarrow", title: "Include cursor") {
                    Toggle("", isOn: $includeCursor).labelsHidden()
                }
                SettingRow(icon: "shadow", title: "Include window shadow") {
                    Toggle("", isOn: $includeWindowShadow).labelsHidden()
                }
            }

            // MARK: Defaults
            Section("Defaults") {
                SettingRow(icon: "camera.viewfinder", title: "Capture mode") {
                    CaptureModePicker(selection: $defaultCaptureMode)
                }

                SettingRow(icon: "timer", title: "Timer delay") {
                    Picker("", selection: $defaultTimerDelay) {
                        ForEach(CaptureDelay.allCases, id: \.self) { d in
                            Text(d.title).tag(d)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles       = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt  = String(localized: "Choose")
        panel.message = String(localized: "Select the folder where screenshots will be saved")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = try? url.bookmarkData(options: [],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: AppSettings.Keys.saveDirectoryBookmark)
        }
        saveDirectory = url.path
    }
}
