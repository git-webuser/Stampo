import Foundation
import Testing
@testable import Stampo

/// A scanned barcode payload is a value, not prose. Everything downstream that
/// treats an archive entry as language — translation today, whatever comes
/// next — depends on that distinction still being there, including after the
/// archive has been written to disk and read back.
@MainActor
@Suite struct ArchiveCodePayloadTests {

    @Test func scanSeparatesPayloadsFromRecognizedText() {
        let codes = [ScanRecognition.Candidate(
            string: "WIFI:S:Net;T:WPA;P:secret;;",
            box: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.2))]
        let lines = [ScanRecognition.Candidate(
            string: "Guest network",
            box: CGRect(x: 0.1, y: 0.3, width: 0.5, height: 0.05))]

        let result = ScanRecognition.assemble(codes: codes, textLines: lines)

        #expect(result.archiveEntries.count == 2)
        #expect(result.archiveEntries.first?.isCode == true)
        #expect(result.archiveEntries.last?.isCode == false)
    }

    @Test func codeFlagSurvivesPersistence() throws {
        let items: [ArchiveItem] = [
            .text(ArchiveText(text: "WIFI:S:Net;T:WPA;P:secret;;", isCodePayload: true)),
            .text(ArchiveText(text: "Guest network")),
        ]
        let data = try #require(NotchArchiveModel.encodePersistedItems(items))
        let restored = NotchArchiveModel.decodePersistedItems(
            data, deferFileChecks: false, fileExists: { _ in true })

        guard case .text(let payload) = restored[0],
              case .text(let prose) = restored[1]
        else {
            Issue.record("restored items are not both text")
            return
        }
        #expect(payload.isCodePayload)
        #expect(!prose.isCodePayload)
    }

    @Test func archivesWrittenBeforeTheFlagExistedDecodeAsProse() throws {
        // Data from a build that never wrote `isCode`. Those entries were
        // treated as prose at the time, and must keep behaving that way rather
        // than silently losing their menu.
        let legacy = Data("""
        [{"kind":"text","text":"Recognized paragraph"}]
        """.utf8)

        let restored = NotchArchiveModel.decodePersistedItems(
            legacy, deferFileChecks: false, fileExists: { _ in true })

        guard case .text(let text) = restored.first else {
            Issue.record("legacy text item did not decode")
            return
        }
        #expect(text.text == "Recognized paragraph")
        #expect(!text.isCodePayload)
    }

    @Test func addingTextCarriesTheFlagIntoTheArchive() {
        // Not emptied first: `add` inserts at the head, so the two entries
        // below are items 0 and 1 whatever the restored archive already held —
        // and the model no longer has a way to empty itself, now that "Clear
        // Archive" is gone and clearing is a selection of everything.
        let model = NotchArchiveModel()
        model.add(text: "Guest network")
        model.add(text: "WIFI:S:Net;T:WPA;P:secret;;", isCodePayload: true)

        guard case .text(let newest) = model.items[0],
              case .text(let older) = model.items[1]
        else {
            Issue.record("archive did not take both text entries")
            return
        }
        #expect(newest.isCodePayload)
        #expect(!older.isCodePayload)
    }
}
