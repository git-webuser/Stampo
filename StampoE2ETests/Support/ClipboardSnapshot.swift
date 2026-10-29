import AppKit

/// Keep user data only in memory. A promised/unreadable type refuses setup,
/// before any input; attachments never contain pasteboard contents.
@MainActor
struct ClipboardSnapshot {
    private let changeCount: Int
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init() throws {
        let pasteboard = NSPasteboard.general
        changeCount = pasteboard.changeCount
        items = try (pasteboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    throw E2EFailure("Cannot preserve a pasteboard type; no input was sent")
                }
                values[type] = data
            }
            return values
        }
    }

    func restoreIfChanged() throws {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != changeCount else { return }
        let restored = try items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values {
                guard item.setData(data, forType: type) else { throw E2EFailure("Cannot restore a pasteboard type") }
            }
            return item
        }
        pasteboard.clearContents()
        guard restored.isEmpty || pasteboard.writeObjects(restored) else { throw E2EFailure("Cannot restore the pasteboard") }
        print("User pasteboard restored: \(restored.count) items")
    }
}
