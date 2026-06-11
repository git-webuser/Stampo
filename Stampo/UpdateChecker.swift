import AppKit
import OSLog

/// Lightweight update notifier: once a day asks the GitHub Releases API for
/// the newest version and offers a link — no downloading, no auto-install,
/// no Sparkle. The only network request Stampo ever makes; can be disabled
/// in Settings → General → Updates.
@MainActor
@Observable
final class UpdateChecker {

    static let shared = UpdateChecker()

    // MARK: Public state (drives the Updates section in General settings)

    /// Newer version found on GitHub, nil when up to date / not checked yet.
    private(set) var availableVersion: String?
    private(set) var isChecking = false

    var lastCheckDate: Date? {
        UserDefaults.standard.object(forKey: AppSettings.Keys.lastUpdateCheck) as? Date
    }

    /// Coarse, localized "how long ago" string — no per-second ticking.
    /// "менее минуты назад" / "2 часа назад" / "вчера" / "неделю назад"...
    var lastCheckDescription: String? {
        guard let date = lastCheckDate else { return nil }
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 {
            return LocaleManager.shared.string("Less than a minute ago")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = LocaleManager.shared.locale
        formatter.dateTimeStyle = .named   // "yesterday" instead of "1 day ago"
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: AppSettings.Keys.checkForUpdates) as? Bool ?? true
    }

    static let releasesPageURL = URL(string: "https://github.com/git-webuser/Stampo/releases")!

    // MARK: Private

    /// All releases so far are GitHub pre-releases, so /releases/latest
    /// (which skips them) would 404 — list endpoint instead.
    private static let apiURL = URL(string: "https://api.github.com/repos/git-webuser/Stampo/releases?per_page=10")!
    private static let checkInterval: TimeInterval = 60 * 60 * 24

    private var timer: Timer?

    private init() {}

    // MARK: - Scheduling

    /// Call once at launch. Performs a delayed check, then re-checks daily.
    func startAutomaticChecks() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.checkIfDue()
        }
    }

    private func checkIfDue() {
        guard Self.isEnabled else { return }
        if let last = lastCheckDate, Date().timeIntervalSince(last) < Self.checkInterval { return }
        Task { await check(userInitiated: false) }
    }

    // MARK: - Checking

    /// Performs one check. User-initiated checks ignore the daily throttle
    /// and the skipped-version preference.
    func check(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        UserDefaults.standard.set(Date(), forKey: AppSettings.Keys.lastUpdateCheck)

        guard let latest = await fetchLatestVersion() else { return }
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

        guard Self.isNewer(latest, than: current) else {
            availableVersion = nil
            return
        }
        availableVersion = latest

        let skipped = UserDefaults.standard.string(forKey: AppSettings.Keys.skippedUpdateVersion)
        if userInitiated || latest != skipped {
            presentUpdateAlert(version: latest, current: current)
        }
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let draft: Bool
        let htmlUrl: String
    }

    private func fetchLatestVersion() async -> String? {
        var request = URLRequest(url: Self.apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else {
            Log.settings.info("Update check failed (network/API)")
            return nil
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let releases = try? decoder.decode([GitHubRelease].self, from: data) else {
            Log.settings.info("Update check failed (decode)")
            return nil
        }
        return releases.first(where: { !$0.draft })?.tagName
    }

    // MARK: - Version comparison

    /// Compares versions like "0.2.2" / "0.3.0-beta.1" (optional leading "v").
    /// Numeric components decide; for equal numbers a release beats a
    /// pre-release ("0.3.0" > "0.3.0-beta.1").
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parse(_ s: String) -> (nums: [Int], pre: String?) {
            let trimmed = s.hasPrefix("v") ? String(s.dropFirst()) : s
            let parts = trimmed.split(separator: "-", maxSplits: 1)
            let nums = parts[0].split(separator: ".").map { Int($0) ?? 0 }
            return (nums, parts.count > 1 ? String(parts[1]) : nil)
        }
        let a = parse(candidate), b = parse(current)
        let count = max(a.nums.count, b.nums.count)
        for i in 0..<count {
            let x = i < a.nums.count ? a.nums[i] : 0
            let y = i < b.nums.count ? b.nums[i] : 0
            if x != y { return x > y }
        }
        // Same numbers: candidate is newer only if it's a release and current is a pre-release.
        return a.pre == nil && b.pre != nil
    }

    // MARK: - Alert

    private func presentUpdateAlert(version: String, current: String) {
        let lm = LocaleManager.shared
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(format: lm.string("Stampo %@ is available"), version)
        alert.informativeText = String(format: lm.string("You have %@. Download the new version from the GitHub releases page."), current)
        alert.addButton(withTitle: lm.string("Open Download Page"))
        alert.addButton(withTitle: lm.string("Later"))
        alert.addButton(withTitle: lm.string("Skip This Version"))

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(Self.releasesPageURL)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(version, forKey: AppSettings.Keys.skippedUpdateVersion)
        default:
            break
        }
    }
}
