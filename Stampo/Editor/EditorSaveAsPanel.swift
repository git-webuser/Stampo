import AppKit

/// `Save As…`: an `NSSavePanel` with a format popup, wired so the chosen
/// format drives both the encoding and the extension in the name field.
///
/// A plain save panel with several `allowedContentTypes` lets the user *type*
/// another extension but never offers the choice; the format is a first-class
/// part of this action, so it gets a real control. Modelled on the panel Preview
/// shows for the same command.
@MainActor final class EditorSaveAsPanel: NSObject {
    /// Retained for the lifetime of the sheet — the popup's target.
    private var panel: NSSavePanel?
    private var format: EditorExportFormat

    init(defaultFormat: EditorExportFormat) {
        self.format = defaultFormat
    }

    /// Presents the panel as a sheet on `window` (or modally when there is no
    /// window). `completion` gets the destination and the format, or nil when
    /// the user cancelled.
    func present(suggestedName: String,
                 directory: URL?,
                 on window: NSWindow?,
                 completion: @escaping (URL, EditorExportFormat) -> Void) {
        let panel = NSSavePanel()
        self.panel = panel
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [format.contentType]
        panel.accessoryView = makeAccessoryView()
        if let directory { panel.directoryURL = directory }

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            defer { self.panel = nil }
            guard response == .OK, let url = panel.url else { return }
            completion(url, self.format)
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    /// Label + popup, sized to fit the panel's width on its own.
    private func makeAccessoryView() -> NSView {
        // "Format" is the same key the capture settings use for the very same
        // choice — one term for one concept. Via LocaleManager, not
        // String(localized:): the in-app language picker decides here, not the
        // process language.
        let label = NSTextField(labelWithString: LocaleManager.shared.string("Format"))
        label.alignment = .right

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for option in EditorExportFormat.allCases {
            popup.addItem(withTitle: option.title)
        }
        popup.selectItem(at: EditorExportFormat.allCases.firstIndex(of: format) ?? 0)
        popup.target = self
        popup.action = #selector(formatChanged(_:))

        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        return stack
    }

    /// Retyping the extension by hand is the user's business; switching the
    /// popup must not fight it, so only the allowed type is updated and AppKit
    /// rewrites the extension in the name field for us.
    @objc private func formatChanged(_ sender: NSPopUpButton) {
        let options = EditorExportFormat.allCases
        guard options.indices.contains(sender.indexOfSelectedItem) else { return }
        format = options[sender.indexOfSelectedItem]
        panel?.allowedContentTypes = [format.contentType]
    }
}
