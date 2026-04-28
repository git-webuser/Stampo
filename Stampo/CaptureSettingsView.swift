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
        saveDirectory.isEmpty
            ? (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.lastPathComponent ?? "Downloads")
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
            Section("File") {
                LabeledContent("Save to") {
                    HStack(spacing: 6) {
                        Text(saveFolderDisplay)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseSaveFolder() }
                    }
                }

                LabeledContent("Format") {
                    Picker("", selection: $fileFormat) {
                        Text("PNG").tag("png")
                        Text("JPEG").tag("jpg")
                        Text("TIFF").tag("tiff")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }

            Section("Filename") {
                Picker("Style", selection: $filenamePreset) {
                    ForEach(FilenamePreset.allCases, id: \.rawValue) { preset in
                        Text(preset.title)
                            .font(.system(.body, design: .monospaced))
                            .tag(preset.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)

                LabeledContent("Preview") {
                    Text(filenamePreview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Section("Behavior") {
                Toggle("Play sound",           isOn: $playSound)
                Toggle("Copy to clipboard",    isOn: $copyToClipboard)
                Toggle("Include cursor",       isOn: $includeCursor)
                Toggle("Include window shadow", isOn: $includeWindowShadow)
            }

            Section("Defaults") {
                LabeledContent("Capture mode") {
                    Picker("", selection: $defaultCaptureMode) {
                        ForEach(CaptureMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                LabeledContent("Timer delay") {
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
        .padding(.vertical, 8)
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
