import AppKit

/// Keep user data only in memory, in its original item/type order. An
/// unreadable promised type refuses setup before any input is sent.
@MainActor
struct ClipboardSnapshot {
    private let changeCount: Int
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init() throws {
        let pasteboard = NSPasteboard.general
        changeCount = pasteboard.changeCount
        items = try (pasteboard.pasteboardItems ?? []).map { item in
            try item.types.map { type in
                guard let data = item.data(forType: type) else {
                    throw E2EFailure("Cannot preserve a pasteboard type; no input was sent")
                }
                return (type, data)
            }
        }
    }

    func restoreIfChanged(allowing extraPayload: String? = nil) throws -> String {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != changeCount else { return "unchanged" }
        let observedCount = pasteboard.changeCount
        // Only the exact plain-string payloads our fixture can copy belong to
        // this test. A concurrent copy by the user or Codex is left untouched.
        let current = pasteboard.pasteboardItems ?? []
        guard current.count == 1, current[0].types == [.string],
              let text = current[0].string(forType: .string),
              text == extraPayload || ["#FF6B4A", "FF6B4A", "Stampo E2E archive text"].contains(text) else {
            return "changed to an unknown payload; left untouched"
        }
        let restored = try items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values {
                guard item.setData(data, forType: type) else { throw E2EFailure("Cannot restore a pasteboard type") }
            }
            return item
        }
        guard pasteboard.changeCount == observedCount else {
            return "changed again before restoration; left untouched"
        }
        pasteboard.clearContents()
        guard restored.isEmpty || pasteboard.writeObjects(restored) else { throw E2EFailure("Cannot restore the pasteboard") }
        return "restored known Stampo payload: \(restored.count) original items"
    }
}
