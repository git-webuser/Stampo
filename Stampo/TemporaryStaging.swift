import Foundation

/// The rule for throwaway files handed to somebody else.
///
/// Three places stage a file in the temp directory so another app can take it:
/// the editor's share sheet, the share sheet's zip of a dropped folder, and the
/// re-encoded copy of a capture whose format disagrees with the setting. All
/// three have the same problem — the file is handed over and then nobody is
/// told when the receiver is done with it. A mail draft may sit unsent for an
/// hour; an AirDrop transfer of a large folder takes as long as it takes.
///
/// So each hand-off gets a directory of its own, named for nothing, and they
/// are cleared by age rather than by count. Deleting the previous one on the
/// way in — which reads as tidy, and is what the share staging used to do —
/// pulls the file out from under a transfer that is still running.
nonisolated enum TemporaryStaging {

    /// Long enough that no plausible transfer or unsent draft outlives it,
    /// short enough that a session of heavy use doesn't leave a temp directory
    /// full of screenshots behind.
    static let lifetime: TimeInterval = 15 * 60

    /// What has to survive a sweep, beyond being recent.
    enum Retention {
        /// Age alone. For a hand-off where any number of files can be live at
        /// once — the share sheet's, which may have several transfers running.
        case byAge

        /// Age, plus the most recent directory whatever its age.
        ///
        /// For a hand-off with a single live slot: the clipboard. Age alone
        /// cannot be its rule, because pasting an hour after copying is an
        /// ordinary way to use a clipboard and the file behind the picture
        /// would be long swept. Nor can "clear the previous one on the way in",
        /// tempting as it is when only one slot exists: two copies in quick
        /// succession stage off the main thread and overlap, and the second
        /// would delete the first's file while the first was still on its way
        /// to the pasteboard.
        ///
        /// Sparing the newest answers both. The clipboard can only ever be
        /// pointing at the newest export, because a copy that writes one also
        /// replaces the clipboard — so the one file that must not go is exactly
        /// the one this keeps, and everything it supersedes is swept on the
        /// ordinary clock.
        case byAgeSparingNewest
    }

    /// A fresh, empty directory under `root`, with the spent ones cleared on
    /// the way in — so the sweeping happens only when something is actually
    /// being staged, and an idle app touches nothing.
    static func makeDirectory(in root: URL,
                              retention: Retention = .byAge,
                              now: Date = Date()) throws -> URL {
        sweep(root, retention: retention, now: now)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Deletes the staging directories under `root` that nothing can still be
    /// reading.
    static func sweep(_ root: URL, retention: Retention = .byAge, now: Date = Date()) {
        for directory in staleDirectories(in: root, retention: retention, now: now) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Which directories `sweep` would delete. Split out so the rule can be
    /// tested against a real directory without waiting a quarter of an hour.
    static func staleDirectories(in root: URL,
                                 retention: Retention = .byAge,
                                 now: Date = Date()) -> [URL] {
        let cutoff = now.addingTimeInterval(-lifetime)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles)) ?? []

        let dated = contents.map { (url: $0, created: creationDate(of: $0)) }
        // A directory with no creation date is one nothing is known about, and
        // a staging directory is disposable by definition — better swept than
        // kept forever. It can't be the newest, either: `distantPast` keeps it
        // from claiming a slot it has no evidence for.
        let spared = retention == .byAgeSparingNewest
            ? dated.max(by: { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) })?.url
            : nil

        return dated
            .filter { $0.url != spared }
            .filter { ($0.created ?? .distantPast) <= cutoff }
            .map(\.url)
    }

    private static func creationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
}
