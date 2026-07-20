import Foundation
import Testing
@testable import Stampo

// MARK: - Merge / removal semantics (pure halves of the model operations)

@Suite struct TrayStackMergeTests {

    private let a = URL(fileURLWithPath: "/tmp/stack/a.png")
    private let b = URL(fileURLWithPath: "/tmp/stack/b.pdf")
    private let c = URL(fileURLWithPath: "/tmp/stack/c")

    @Test func firstDropCreatesStack() {
        let (stack, fresh) = TrayStack.merging(nil, droppedFiles: [a, b])
        #expect(stack.urls == [a, b])
        #expect(fresh == [a, b])
    }

    @Test func batchIsDedupedInOrder() {
        let (stack, fresh) = TrayStack.merging(nil, droppedFiles: [a, b, a, a, b])
        #expect(stack.urls == [a, b])
        #expect(fresh == [a, b])
    }

    @Test func urlsAreStandardizedBeforeDedup() {
        let sneaky = URL(fileURLWithPath: "/tmp/stack/../stack/a.png")
        let (stack, fresh) = TrayStack.merging(nil, droppedFiles: [a, sneaky])
        #expect(stack.urls == [a])
        #expect(fresh == [a])
    }

    @Test func secondDropAccumulatesAndKeepsIdentity() {
        let (first, _) = TrayStack.merging(nil, droppedFiles: [a])
        let (second, fresh) = TrayStack.merging(first, droppedFiles: [b, a, c])
        #expect(second.id == first.id)
        #expect(second.urls == [a, b, c])
        #expect(fresh == [b, c])
    }

    @Test func duplicateOnlyDropAddsNothing() {
        let (first, _) = TrayStack.merging(nil, droppedFiles: [a, b])
        let (second, fresh) = TrayStack.merging(first, droppedFiles: [b, a])
        #expect(second.urls == first.urls)
        #expect(fresh.isEmpty)
    }

    @Test func removingMemberKeepsIdentity() {
        let (stack, _) = TrayStack.merging(nil, droppedFiles: [a, b])
        let updated = stack.removingMember(a)
        #expect(updated?.id == stack.id)
        #expect(updated?.urls == [b])
    }

    @Test func removingLastMemberEmptiesStack() {
        let (stack, _) = TrayStack.merging(nil, droppedFiles: [a])
        #expect(stack.removingMember(a) == nil)
    }

    @Test func removingUnknownMemberChangesNothing() {
        let (stack, _) = TrayStack.merging(nil, droppedFiles: [a])
        #expect(stack.removingMember(b)?.urls == [a])
    }
}

// MARK: - Persistence codec round-trips

@Suite struct TrayStackPersistenceTests {

    private let a = URL(fileURLWithPath: "/tmp/stack/a.png")
    private let b = URL(fileURLWithPath: "/tmp/stack/b.pdf")

    @Test func stackSurvivesRoundTripAlongsideOtherKinds() throws {
        let items: [TrayItem] = [
            .stack(TrayStack(urls: [a, b])),
            .text(TrayText(text: "hello")),
            .screenshot(TrayScreenshot(url: a)),
        ]
        let data = try #require(NotchTrayModel.encodePersistedItems(items))
        let restored = NotchTrayModel.decodePersistedItems(
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
        let data = try #require(NotchTrayModel.encodePersistedItems([.stack(TrayStack(urls: [a, b]))]))
        let restored = NotchTrayModel.decodePersistedItems(
            data, deferFileChecks: false, fileExists: { $0 == a.path })

        guard case .stack(let stack) = restored.first else {
            Issue.record("stack missing after restore")
            return
        }
        #expect(stack.urls == [a])
    }

    @Test func fullyMissingStackIsDroppedWhole() throws {
        let data = try #require(NotchTrayModel.encodePersistedItems([.stack(TrayStack(urls: [a, b]))]))
        let restored = NotchTrayModel.decodePersistedItems(
            data, deferFileChecks: false, fileExists: { _ in false })
        #expect(restored.isEmpty)
    }

    @Test func deferredRestoreNeverChecksFiles() throws {
        let data = try #require(NotchTrayModel.encodePersistedItems([
            .stack(TrayStack(urls: [a, b])),
            .screenshot(TrayScreenshot(url: a)),
        ]))
        let restored = NotchTrayModel.decodePersistedItems(
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
        let restored = NotchTrayModel.decodePersistedItems(
            Data(legacy.utf8), deferFileChecks: false, fileExists: { _ in true })
        #expect(restored.count == 2)
    }
}

// MARK: - Collect Files hotkey metadata

@Suite struct CollectFilesHotkeyTests {

    @Test func collectFilesRowMetadataIsFilledIn() {
        #expect(HotkeyAction.collectFiles.rawValue == 9)
        #expect(HotkeyAction.collectFiles.labelKey == "Collect Files")
        #expect(HotkeyAction.collectFiles.icon == "tray.and.arrow.down")
        #expect(HotkeyAction.collectFiles.defaultCombo.displayString == "⌃⌥⌘T")
    }

    @Test func collectFilesDefaultComboIsNotSystemReserved() {
        let result = HotkeyValidator.validate(
            HotkeyAction.collectFiles.defaultCombo, for: .collectFiles)
        #expect(result != .systemReserved)
        #expect(result != .noStrongModifier)
    }
}
