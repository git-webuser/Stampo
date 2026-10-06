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
    @AppStorage(AppSettings.Keys.excludeScrollbars) private var excludeScrollbars = true
    @AppStorage(AppSettings.Keys.scrollLengthLimit, store: AppSettings.store)
    private var scrollLengthLimit = ScrollLengthLimit.default
    @AppStorage(AppSettings.Keys.scrollShrinkToFit, store: AppSettings.store)
    private var scrollShrinkToFit = false
    @Environment(\.locale) private var locale
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

    /// What the chosen length comes to, as the row's second line: screens of the
    /// page, and the size of the file in the format chosen above. Like the
    /// filename's, it answers the picker beside it.
    private var lengthLimitDescription: LocalizedStringKey {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let estimate = ScrollLengthLimit.estimate(
            limit: scrollLengthLimit, format: fileFormat,
            screenPoints: screen?.frame.size ?? CGSize(width: 1440, height: 900),
            backingScale: screen?.backingScaleFactor ?? 2)
        return "About \(estimate.screens) screens · \(fileFormatName) about \(Self.sizeText(estimate.bytes, locale: locale))"
    }

    private var fileFormatName: String {
        switch fileFormat {
        case "jpg", "jpeg": return "JPEG"
        case "tiff", "tif": return "TIFF"
        default:            return "PNG"
        }
    }

    /// Megabytes (millions of bytes, as Finder counts them), always: a range
    /// reads as one unit, and the largest estimate — a TIFF on a big display —
    /// is about a gigabyte, not worth a second unit. Written in the app's
    /// language, not the system's, which is what `ByteCountFormatter` would
    /// use: the sentence around the number is in the app's.
    static func sizeText(_ bytes: ClosedRange<Int64>, locale: Locale) -> String {
        func megabytes(_ count: Int64) -> String {
            let value = Double(count) / 1_000_000
            // One decimal for the small ones, where a decimal is a fifth of the
            // number; none above ten.
            return value.formatted(.number.precision(.fractionLength(0...(value < 10 ? 1 : 0))).locale(locale))
        }
        let unit = LocaleManager.string("MB", locale: locale)
        guard bytes.lowerBound != bytes.upperBound else {
            return "\(megabytes(bytes.upperBound)) \(unit)"
        }
        return "\(megabytes(bytes.lowerBound))–\(megabytes(bytes.upperBound)) \(unit)"
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
            Section("Filename") {
                // The description is the live result of the choice beside it,
                // which is why it belongs on the row rather than under the
                // section: it reads as an answer to the picker, not a note
                // about the group.
                SettingRow(
                    icon: "textformat",
                    title: "Style",
                    description: "Saved as \(filenamePreview)"
                ) {
                    Picker("", selection: $filenamePreset) {
                        ForEach(FilenamePreset.allCases, id: \.rawValue) { preset in
                            Text(LocalizedStringKey(preset.name)).tag(preset.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
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

            // MARK: Scrolling screenshot
            Section("Scrolling Screenshot") {
                SettingRow(
                    icon: "scroll",
                    title: "Exclude scrollbars",
                    description: "Scrolling capture only. Excludes a narrow viewport edge where scrollbars appear; content near that edge may also be cropped."
                ) {
                    Toggle("", isOn: $excludeScrollbars).labelsHidden()
                }
                SettingRow(icon: "ruler", title: "Length limit", description: lengthLimitDescription) {
                    Picker("", selection: $scrollLengthLimit) {
                        ForEach(ScrollLengthLimit.options, id: \.self) { limit in
                            Text(verbatim: "\(limit.formatted(.number.locale(locale))) px").tag(limit)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                SettingRow(
                    icon: "arrow.down.right.and.arrow.up.left",
                    title: "Shrink to fit",
                    description: "At the limit the image drops to standard resolution (1x) and the capture continues — twice as much of the page fits."
                ) {
                    Toggle("", isOn: $scrollShrinkToFit).labelsHidden()
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
