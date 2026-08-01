import AppKit
import Foundation
import Testing
@testable import Stampo

/// A dropped "file" is routinely a directory on macOS (`.icon`, `.app`,
/// `.rtfd`, a plain folder). Share extensions take the URL and then read it as
/// a file — so directories have to be zipped before they reach the sheet.
@Suite struct ShareItemPreparerTests {

    /// Builds a package-shaped directory: a wrapper holding a file and a
    /// subfolder, the same shape as the `.icon` bundles that surfaced this.
    private func makePackage() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-test-\(UUID().uuidString).icon", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Assets", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: root.appendingPathComponent("icon.json"))
        return root
    }

    private func makeFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-test-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: url)
        return url
    }

    @Test func directoriesAreRecognized() throws {
        let package = try makePackage()
        let file = try makeFile()
        defer {
            try? FileManager.default.removeItem(at: package)
            try? FileManager.default.removeItem(at: file)
        }
        #expect(ShareItemPreparer.isDirectory(package))
        #expect(ShareItemPreparer.isDirectory(package as NSURL))
        #expect(!ShareItemPreparer.isDirectory(file))
        #expect(!ShareItemPreparer.isDirectory("a string"))
    }

    @Test func packageBecomesAZipOnDisk() throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }

        let prepared = ShareItemPreparer.prepare([package as NSURL])
        #expect(!prepared.hasFailures)
        let url = try #require(prepared.items.first as? NSURL as URL?)

        #expect(url != package)
        #expect(url.pathExtension == "zip")
        #expect(FileManager.default.fileExists(atPath: url.path))
        // A zip, not a directory — that is the whole point of the step.
        #expect((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false)
        let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size > 0)
    }

    @Test func plainFilesAndStringsPassThroughUntouched() throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let prepared = ShareItemPreparer.prepare([file as NSURL, "hello" as NSString]).items
        // Identity matters: re-staging a plain file would strip its name and
        // break AirDrop's "send the actual file" behaviour.
        #expect((prepared.first as? NSURL) as URL? == file)
        #expect(prepared.last as? NSString == "hello")
    }

    /// `.isDirectoryKey` describes the link, not its target, so a symlink to a
    /// folder used to pass through as a "file" and fail exactly the way a
    /// package does. Symlinks to plain files stay untouched — every reader
    /// follows those on open.
    @Test func symlinkToAFolderIsZippedAndSymlinkToAFileIsNot() throws {
        let package = try makePackage()
        let file = try makeFile()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-test-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folderLink = root.appendingPathComponent("folder-link")
        let fileLink = root.appendingPathComponent("file-link")
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: package)
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: file)
        defer {
            try? FileManager.default.removeItem(at: package)
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: root)
        }

        #expect(ShareItemPreparer.isDirectory(folderLink))
        #expect(!ShareItemPreparer.isDirectory(fileLink))

        let prepared = ShareItemPreparer.prepare([folderLink as NSURL, fileLink as NSURL])
        #expect(((prepared.items[0] as? NSURL) as URL?)?.pathExtension == "zip")
        #expect((prepared.items[1] as? NSURL) as URL? == fileLink)
    }

    /// An unreadable folder can't be staged. It is still handed over, but the
    /// caller has to know so it can say something instead of failing silently.
    @Test func unreadableFolderIsReportedAsAFailure() throws {
        let locked = try makePackage()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: locked)
        }

        let prepared = ShareItemPreparer.prepare([locked as NSURL])
        #expect(prepared.hasFailures)
        #expect((prepared.items.first as? NSURL) as URL? == locked)
    }

    @Test func everyDirectoryInAMixedBatchIsZipped() throws {
        let package = try makePackage()
        let file = try makeFile()
        defer {
            try? FileManager.default.removeItem(at: package)
            try? FileManager.default.removeItem(at: file)
        }
        let prepared = ShareItemPreparer.prepare([package as NSURL, file as NSURL]).items
        #expect(prepared.count == 2)
        #expect(((prepared[0] as? NSURL) as URL?)?.pathExtension == "zip")
        #expect((prepared[1] as? NSURL) as URL? == file)
    }
}
