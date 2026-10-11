import CoreGraphics
import Testing
@testable import Stampo

/// How the area Accessibility found is known to be a web page
/// (`ScrollWebPage.kind`): by its own role, by a web area among its children,
/// or, when Accessibility will not give the children, by the window being a
/// browser's and the area most of it.
@Suite struct ScrollWebPageTests {
    private let window = CGSize(width: 1280, height: 800)
    private let big = CGSize(width: 1280, height: 687)
    private let safari = "com.apple.Safari", brave = "com.brave.Browser", finder = "com.apple.finder"

    private func kind(_ role: String, children: [String]? = nil, bundle: String? = nil,
                      area: CGSize? = nil) -> ScrollWebPage.Kind? {
        ScrollWebPage.kind(role: role, childRoles: children, bundleIdentifier: bundle,
                           areaSize: area ?? big, windowSize: window)
    }

    /// Safari, and Chromium with a whole tree: the chain has the web area.
    @Test func aWebAreaIsAPageWhateverTheProcess() {
        #expect(kind("AXWebArea") == .webArea)
        #expect(kind("AXWebArea", bundle: finder, area: CGSize(width: 100, height: 100)) == .webArea)
    }

    /// Chromium with a partial tree, 2026-10-10-153037 and 2026-10-11-120023: the
    /// chain stops at an AXScrollArea, which has the web area for a child.
    @Test func aScrollAreaWithAWebAreaAmongItsChildrenIsAPage() {
        #expect(kind("AXScrollArea", children: ["AXGroup", "AXWebArea", "AXScrollBar"]) == .childWebArea)
        #expect(kind("AXScrollArea", children: ["AXWebArea"], bundle: nil) == .childWebArea)
    }

    /// The list of a Finder window, 2026-10-10-150957, 163756, 153513: children
    /// known, no web area among them: not a page, whatever the process.
    @Test func aScrollAreaWithKnownChildrenAndNoWebAreaIsNotAPage() {
        #expect(kind("AXScrollArea", children: ["AXList", "AXScrollBar"], bundle: finder) == nil)
        // Even in a browser's window, and even most of it.
        #expect(kind("AXScrollArea", children: ["AXList"], bundle: safari) == nil)
    }

    @Test func withNoChildrenToBeHadABrowserWindowThatTheAreaMostlyFillsIsAPage() {
        for children in [nil, []] as [[String]?] {
            #expect(kind("AXScrollArea", children: children, bundle: brave) == .browserWindow)
            #expect(kind("AXScrollArea", children: children, bundle: safari) == .browserWindow)
        }
        // Exactly half the window is enough, less is not.
        let half = CGSize(width: 1280, height: 400)
        #expect(kind("AXScrollArea", bundle: brave, area: half) == .browserWindow)
        #expect(kind("AXScrollArea", bundle: brave, area: CGSize(width: 1280, height: 399)) == nil)
    }

    @Test func withNoChildrenToBeHadAnythingButABrowserIsNotAPage() {
        #expect(kind("AXScrollArea", bundle: finder) == nil)
        #expect(kind("AXScrollArea", bundle: nil) == nil)
        #expect(kind("AXScrollArea", bundle: "com.example.App") == nil)
    }

    @Test func otherRolesAreNotPages() {
        #expect(kind("AXTable", children: ["AXWebArea"], bundle: safari) == nil)
        #expect(kind("AXList", bundle: safari) == nil)
        #expect(kind("AXGroup", children: nil, bundle: brave) == nil)
    }

    @Test func aWindowWithNoSizeIsNotAPage() {
        #expect(ScrollWebPage.kind(role: "AXScrollArea", childRoles: nil, bundleIdentifier: brave,
                                   areaSize: big, windowSize: .zero) == nil)
    }

    @Test func theBrowsersAreKnownByBundleIdentifier() {
        for bundle in ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "org.chromium.Chromium",
                       "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
                       "ru.yandex.desktop.yandex-browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
                       "org.mozilla.firefox"] {
            #expect(ScrollWebPage.browserBundles.contains(bundle), "\(bundle)")
        }
        #expect(!ScrollWebPage.browserBundles.contains("com.apple.finder"))
    }

    @Test func theKindIsSaidInTheLog() {
        #expect(ScrollWebPage.Kind.webArea.rawValue == "web area")
        #expect(ScrollWebPage.Kind.childWebArea.rawValue == "child web area")
        #expect(ScrollWebPage.Kind.browserWindow.rawValue == "browser window")
    }
}
