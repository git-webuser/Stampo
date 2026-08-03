import Foundation
import Testing
@testable import Stampo

/// Files staged for another app are the one thing here nobody is told the end
/// of: a mail draft sits unsent, an AirDrop transfer of a big folder runs long
/// after the sheet closed. Both bugs this rule replaces were the same mistake
/// in different clothes — deleting a staged file while a receiver was still
/// reading it — so what is pinned down below is exactly what survives a sweep.
@Suite struct TemporaryStagingTests {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A staging directory with a chosen creation date, so the age rule can be
    /// tested without waiting a quarter of an hour.
    @discardableResult
    private func makeAged(_ age: TimeInterval, in root: URL) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.creationDate: Date().addingTimeInterval(-age)]
        )
        return directory
    }

    @Test func aFreshDirectoryIsEmptyAndItsOwn() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try TemporaryStaging.makeDirectory(in: root)
        let second = try TemporaryStaging.makeDirectory(in: root)

        #expect(first != second)
        #expect(try FileManager.default.contentsOfDirectory(atPath: first.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    /// The whole point: staging a second share must not disturb the first,
    /// whose zip may still be uploading. This is what the old
    /// `removeItem(at: root)` got wrong.
    @Test func stagingAgainLeavesTheRecentOneAlone() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let earlier = try TemporaryStaging.makeDirectory(in: root)
        let payload = earlier.appendingPathComponent("upload.zip")
        try Data("still going".utf8).write(to: payload)

        _ = try TemporaryStaging.makeDirectory(in: root)

        #expect(FileManager.default.fileExists(atPath: payload.path))
    }

    @Test func staleDirectoriesGoOnTheWayIn() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let stale = try makeAged(TemporaryStaging.lifetime + 60, in: root)
        let recent = try makeAged(60, in: root)

        _ = try TemporaryStaging.makeDirectory(in: root)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
    }

    /// The boundary is only interesting because it decides between deleting a
    /// file somebody may hold and keeping one nobody wants: exactly at the
    /// lifetime the directory goes.
    ///
    /// Compared by name, not by URL: `contentsOfDirectory` hands back the
    /// resolved `/private/var` spelling of a path built from `/var`, and the
    /// two URLs are not equal even though they are the same directory.
    @Test func theCutoffIsInclusive() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let atCutoff = try makeAged(TemporaryStaging.lifetime, in: root)
        let justInside = try makeAged(TemporaryStaging.lifetime - 30, in: root)

        let stale = TemporaryStaging.staleDirectories(in: root).map(\.lastPathComponent)

        #expect(stale.contains(atCutoff.lastPathComponent))
        #expect(!stale.contains(justInside.lastPathComponent))
    }

    /// `byAgeSparingNewest` is the clipboard's rule: the one export it can be
    /// pointing at survives however long the user leaves it there.
    @Test func theNewestIsSparedNoMatterHowOld() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let older = try makeAged(TemporaryStaging.lifetime * 4, in: root)
        let newest = try makeAged(TemporaryStaging.lifetime * 2, in: root)

        let stale = TemporaryStaging
            .staleDirectories(in: root, retention: .byAgeSparingNewest)
            .map(\.lastPathComponent)

        #expect(stale.contains(older.lastPathComponent))
        #expect(!stale.contains(newest.lastPathComponent))
    }

    /// Sparing one is not the same as keeping everything recent: the rest of
    /// the directory is still swept on the ordinary clock, or a long session of
    /// copying would never give anything back.
    @Test func sparingTheNewestStillSweepsTheRest() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeAged(TemporaryStaging.lifetime + 600, in: root)
        try makeAged(TemporaryStaging.lifetime + 300, in: root)
        let newest = try makeAged(TemporaryStaging.lifetime + 60, in: root)

        TemporaryStaging.sweep(root, retention: .byAgeSparingNewest)

        let left = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(left == [newest.lastPathComponent])
    }

    /// Sweeping is the first thing every staging call does, and the root does
    /// not exist until the first one — it must not be an error.
    @Test func sweepingAMissingRootIsHarmless() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging-test-absent-\(UUID().uuidString)", isDirectory: true)

        #expect(TemporaryStaging.staleDirectories(in: root).isEmpty)
        TemporaryStaging.sweep(root)
    }
}

/// The clipboard's throwaway is swept on a clock of its own, and that split is
/// the fix for a copy that quietly stopped pasting a file after fifteen
/// minutes. What matters is that the two rules stay apart.
@MainActor
@Suite final class ClipboardExportTests {

    /// A staging root per test instance: the clipboard rule is "clear what was
    /// there", and two of these sharing the app's real temp directory — or
    /// sharing it with `PasteboardFormatTests`, which goes down the same path —
    /// would be clearing each other.
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("clipboard-test-\(UUID().uuidString)", isDirectory: true)
    private let store: ScreenshotFileStore

    init() {
        store = ScreenshotFileStore(stagingRoot: root)
    }

    /// A class rather than a struct purely for this: the staging root is real,
    /// and a run of the suite should not leave a pile of them behind.
    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private var bytes: Data { Data("not really a png, and it doesn't need to be".utf8) }

    /// Copying again must not take the previous file down on the spot: two
    /// copies in quick succession stage off the main thread and overlap, so the
    /// earlier one can still be on its way to the pasteboard. It goes on the
    /// ordinary clock instead, once it is no longer the newest.
    @Test func copyingAgainLeavesTheFileBeforeItInPlace() throws {
        let first = try store.writeClipboardExport(bytes, named: "first", format: "png")
        let second = try store.writeClipboardExport(bytes, named: "second", format: "png")

        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    /// The regression itself: a share staged after the copy must leave the
    /// clipboard's file where it is, whatever its age. They shared a root
    /// before, and the share sheet's fifteen-minute sweep took the clipboard
    /// down with it.
    @Test func stagingAShareLeavesTheClipboardAlone() throws {
        let copied = try store.writeClipboardExport(bytes, named: "copied", format: "png")

        _ = try store.writeTemporaryExport(bytes, named: "shared", format: "png")

        #expect(FileManager.default.fileExists(atPath: copied.path))
    }

    /// And the file the clipboard is on survives a wait no share sheet would:
    /// the export is hours stale and still there, because nothing newer has
    /// taken its place.
    @Test func theCopiedFileOutlivesTheShareSheetsClock() throws {
        let copied = try store.writeClipboardExport(bytes, named: "copied", format: "png")
        let staleByNow = Date().addingTimeInterval(TemporaryStaging.lifetime * 8)

        TemporaryStaging.sweep(root.appendingPathComponent("Clipboard", isDirectory: true),
                               retention: .byAgeSparingNewest,
                               now: staleByNow)

        #expect(FileManager.default.fileExists(atPath: copied.path))
    }

    /// Name and extension survive the trip: they are what Mail and Finder show
    /// for the pasted file, and a bare ".png" is invisible in both.
    @Test func theFileKeepsItsNameAndFormat() throws {
        let url = try store.writeClipboardExport(bytes, named: "Screenshot 2026-08-03", format: "jpg")
        #expect(url.lastPathComponent == "Screenshot 2026-08-03.jpg")

        let unnamed = try store.writeClipboardExport(bytes, named: "", format: "png")
        #expect(unnamed.lastPathComponent == "Screenshot.png")
    }
}
