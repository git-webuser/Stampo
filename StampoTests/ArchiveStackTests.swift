import Foundation
import Testing
@testable import Stampo

// MARK: - Merge / removal semantics (pure halves of the model operations)

@Suite struct ArchiveStackMergeTests {

    private let a = URL(fileURLWithPath: "/tmp/stack/a.png")
    private let b = URL(fileURLWithPath: "/tmp/stack/b.pdf")
    private let c = URL(fileURLWithPath: "/tmp/stack/c")

    @Test func firstDropCreatesStack() {
        let (stack, fresh) = ArchiveStack.merging(nil, droppedFiles: [a, b])
        #expect(stack.urls == [a, b])
        #expect(fresh == [a, b])
    }

    @Test func batchIsDedupedInOrder() {
        let (stack, fresh) = ArchiveStack.merging(nil, droppedFiles: [a, b, a, a, b])
        #expect(stack.urls == [a, b])
        #expect(fresh == [a, b])
    }

    @Test func urlsAreStandardizedBeforeDedup() {
        let sneaky = URL(fileURLWithPath: "/tmp/stack/../stack/a.png")
        let (stack, fresh) = ArchiveStack.merging(nil, droppedFiles: [a, sneaky])
        #expect(stack.urls == [a])
        #expect(fresh == [a])
    }

    @Test func secondDropAccumulatesAndKeepsIdentity() {
        let (first, _) = ArchiveStack.merging(nil, droppedFiles: [a])
        let (second, fresh) = ArchiveStack.merging(first, droppedFiles: [b, a, c])
        #expect(second.id == first.id)
        #expect(second.urls == [a, b, c])
        #expect(fresh == [b, c])
    }

    @Test func duplicateOnlyDropAddsNothing() {
        let (first, _) = ArchiveStack.merging(nil, droppedFiles: [a, b])
        let (second, fresh) = ArchiveStack.merging(first, droppedFiles: [b, a])
        #expect(second.urls == first.urls)
        #expect(fresh.isEmpty)
    }

    @Test func removingMemberKeepsIdentity() {
        let (stack, _) = ArchiveStack.merging(nil, droppedFiles: [a, b])
        let updated = stack.removingMember(a)
        #expect(updated?.id == stack.id)
        #expect(updated?.urls == [b])
    }

    @Test func removingLastMemberEmptiesStack() {
        let (stack, _) = ArchiveStack.merging(nil, droppedFiles: [a])
        #expect(stack.removingMember(a) == nil)
    }

    @Test func removingUnknownMemberChangesNothing() {
        let (stack, _) = ArchiveStack.merging(nil, droppedFiles: [a])
        #expect(stack.removingMember(b)?.urls == [a])
    }

    @Test func folderIsTheMembersParent() {
        let (stack, _) = ArchiveStack.merging(nil, droppedFiles: [a, b])
        #expect(stack.folder?.path == "/tmp/stack")
    }
}

// MARK: - Folder grouping (one stack per source folder)

@Suite struct ArchiveStackGroupingTests {

    private let downA = URL(fileURLWithPath: "/tmp/Downloads/a.png")
    private let downB = URL(fileURLWithPath: "/tmp/Downloads/b.pdf")
    private let deskC = URL(fileURLWithPath: "/tmp/Desktop/c.txt")
    private let deskD = URL(fileURLWithPath: "/tmp/Desktop/d.txt")

    @Test func singleFolderYieldsOneGroup() {
        let groups = ArchiveStack.groupedByFolder([downA, downB])
        #expect(groups.count == 1)
        #expect(groups[0].folder.path == "/tmp/Downloads")
        #expect(groups[0].urls == [downA, downB])
    }

    @Test func twoFoldersYieldTwoGroupsInFirstSeenOrder() {
        let groups = ArchiveStack.groupedByFolder([deskC, downA, deskD, downB])
        #expect(groups.map(\.folder.path) == ["/tmp/Desktop", "/tmp/Downloads"])
        #expect(groups[0].urls == [deskC, deskD])
        #expect(groups[1].urls == [downA, downB])
    }

    @Test func groupingDedupesAcrossTheBatch() {
        let groups = ArchiveStack.groupedByFolder([downA, downA, deskC])
        #expect(groups.count == 2)
        #expect(groups[0].urls == [downA])
        #expect(groups[1].urls == [deskC])
    }

    @Test func groupFolderMatchesStackFolder() {
        // The grouping key must equal a resulting stack's derived folder, so a
        // later drop from the same folder finds and extends the right stack.
        let group = ArchiveStack.groupedByFolder([downA])[0]
        let (stack, _) = ArchiveStack.merging(nil, droppedFiles: group.urls)
        #expect(stack.folder == group.folder)
    }
}

// Note: `add(droppedFiles:)` is deliberately not exercised through a live
// NotchArchiveModel here — the model reads/writes UserDefaults.standard, which in
// the Stampo.app-hosted test bundle is the user's real archive (restoring their
// stacks into the fixture and risking a persist over their data). Its logic is
// a thin loop over the pure `groupedByFolder` + `merging` helpers, both covered
// above; grouping the tests keeps them isolated and side-effect free.

// MARK: - Persistence codec round-trips

@Suite struct ArchiveStackPersistenceTests {

    private let a = URL(fileURLWithPath: "/tmp/stack/a.png")
    private let b = URL(fileURLWithPath: "/tmp/stack/b.pdf")

    @Test func stackSurvivesRoundTripAlongsideOtherKinds() throws {
        let items: [ArchiveItem] = [
            .stack(ArchiveStack(urls: [a, b])),
            .text(ArchiveText(text: "hello")),
            .screenshot(ArchiveScreenshot(url: a)),
        ]
        let data = try #require(NotchArchiveModel.encodePersistedItems(items))
        let restored = NotchArchiveModel.decodePersistedItems(
            data, deferFileChecks: false, fileExists: { _ in true })

        #expect(restored.count == 3)
        guard case .stack(let stack) = restored[0] else {
            Issue.record("first restored item is not a stack")
            return
        }
        #expect(stack.urls == [a, b])
        guard case .text(let text) = restored[1] else {
            Issue.record("second restored item is not text")
            return
        }
        #expect(text.text == "hello")
    }

    @Test func missingMembersAreDroppedOnRestore() throws {
        let data = try #require(NotchArchiveModel.encodePersistedItems([.stack(ArchiveStack(urls: [a, b]))]))
        let restored = NotchArchiveModel.decodePersistedItems(
            data, deferFileChecks: false, fileExists: { $0 == a.path })

        guard case .stack(let stack) = restored.first else {
            Issue.record("stack missing after restore")
            return
        }
        #expect(stack.urls == [a])
    }

    @Test func fullyMissingStackIsDroppedWhole() throws {
        let data = try #require(NotchArchiveModel.encodePersistedItems([.stack(ArchiveStack(urls: [a, b]))]))
        let restored = NotchArchiveModel.decodePersistedItems(
            data, deferFileChecks: false, fileExists: { _ in false })
        #expect(restored.isEmpty)
    }

    @Test func deferredRestoreNeverChecksFiles() throws {
        let data = try #require(NotchArchiveModel.encodePersistedItems([
            .stack(ArchiveStack(urls: [a, b])),
            .screenshot(ArchiveScreenshot(url: a)),
        ]))
        let restored = NotchArchiveModel.decodePersistedItems(
            data, deferFileChecks: true,
            fileExists: { _ in
                Issue.record("fileExists must not be called on the deferred path")
                return false
            })
        #expect(restored.count == 2)
    }

    @Test func preStackDataStillDecodes() throws {
        // Data written before the stack kind existed has no "paths" field.
        let legacy = ##"[{"kind":"text","text":"old"},{"kind":"color","hex":"#FF0000"}]"##
        let restored = NotchArchiveModel.decodePersistedItems(
            Data(legacy.utf8), deferFileChecks: false, fileExists: { _ in true })
        #expect(restored.count == 2)
    }
}

// MARK: - Collect Files hotkey metadata

@Suite struct CollectFilesHotkeyTests {

    /// The row is named for the flow it enables, not for the mechanism. It was
    /// "Pin Panel" — named for what the keystroke literally does — until that
    /// turned out to disagree with everything around it: the icon draws files
    /// Renamed from Collect files: the action opens the archive pinned, which
    /// is the same state as the pin button in the archive header, and it now
    /// carries that button's glyph and wording. "Pin" no longer clashes with
    /// the row above — floating a capture above all windows took a distinct
    /// glyph precisely so these two stopped looking alike at 14pt.
    @Test func pinPanelRowMetadataIsFilledIn() {
        #expect(HotkeyAction.collectFiles.rawValue == 9)
        #expect(HotkeyAction.collectFiles.labelKey == "Pin Panel")
        #expect(HotkeyAction.collectFiles.icon == "pin")
        #expect(HotkeyAction.collectFiles.defaultCombo.displayString == "⌃⌥⌘P")
    }

    @Test func collectFilesDefaultComboIsNotSystemReserved() {
        let result = HotkeyValidator.validate(
            HotkeyAction.collectFiles.defaultCombo, for: .collectFiles)
        #expect(result != .systemReserved)
        #expect(result != .noStrongModifier)
    }
}
