import AppKit
import ApplicationServices
import XCTest

@MainActor
final class HotkeyE2ETests: E2ETestCase {
    func testPanelAndPinHotkeys() throws {
        try app.launch(fixture: true)
        try recordWindowBaseline()

        try app.input.press("⌃⌥⌘N")
        _ = try settledPanel()
        _ = try required(.panelModeMenu)
        XCTAssertNil(try app.liveElement(.archiveBack), "Toggle hotkey opened Archive instead of Main")
        try artifacts.step("toggle-panel-main")
        try app.input.press("ESC")
        try expectClosed("Esc did not close Main opened by togglePanel")

        try app.input.press("⌃⌥⌘P")
        let pinnedFrame = try expectPinnedArchive(label: "collect-files-pinned")
        try clickFixtureOutsidePanel(frame: pinnedFrame, label: "pinned-archive")
        let disappeared = try waitUntil(timeout: 1) { try self.app.liveElement(.panel) == nil }
        XCTAssertFalse(disappeared, "Outside click closed the pinned archive")
        let retained = try expectPinnedArchive(label: "pinned-archive-after-outside-click")
        XCTAssertTrue(WindowHitTest.framesMatch(retained, pinnedFrame),
                      "Outside click changed the pinned archive frame: \(pinnedFrame) -> \(retained)")
        // openArchivePinned is a toggle: the same chord dismisses the pinned
        // archive, and hideAnimated clears its pin state.
        try app.input.press("⌃⌥⌘P")
        try expectClosed("Second collectFiles hotkey did not close the pinned archive")

        try app.input.press("⌃⌥⌘N")
        let mainFrame = try settledPanel()
        _ = try required(.panelModeMenu)
        XCTAssertNil(try app.liveElement(.archiveBack), "Reopening after pinned hide should return to Main")
        XCTAssertNil(try unpinButton(), "Hiding the archive left the reopened panel pinned")
        try artifacts.step("main-reopened-after-pinned-hide")
        // The outside click also probes whether a surviving pin still
        // suppresses auto-hide on Main.
        try clickFixtureOutsidePanel(frame: mainFrame, label: "reopened-main")
        try expectClosed("Outside click did not close Main reopened after pinned hide")

        try app.input.press("⌃⌥⌘P")
        try expectPinnedArchive(label: "collect-files-pinned-again")
        // Pinning prevents outside dismissal, not the archive's Esc owner.
        // With no expanded stack or selection, escapeAction is hidePanel.
        try app.input.press("ESC")
        try expectClosed("Esc did not close the pinned archive with no inner layers")
    }

    func testWindowHotkeyCapturesFixture() throws {
        try app.launch(fixture: true)
        try app.requireScreenRecording()
        try recordWindowBaseline()
        let pasteboardCount = NSPasteboard.general.changeCount

        // The HUD caches its panel after it goes off screen. Prime that cache
        // and take the full window baseline with its hidden window included.
        _ = try captureWindowBaseline(name: "before-thumbnail-warmup")
        let first = try captureFixture(excluding: [], label: "first")
        try expectThumbnailDismissed(first, label: "first")
        try recordWindowBaseline(primePanelCache: false)

        // A second G also checks preSelection was cleared. N can reopen Main
        // even when that state is stale and would mask the blocked second G.
        let capture = try captureFixture(excluding: [first.png], label: "second")
        let bitmap = try Files.Bitmap(png: capture.png)
        let scale = try XCTUnwrap(NSScreen.screens.first).backingScaleFactor
        let leftX = bitmap.width / 4
        let row = bitmap.height * 2 / 3
        let left = try bitmap.rgba(x: leftX, y: row)
        let right = try bitmap.rgba(x: bitmap.width * 3 / 4, y: row)
        // A window PNG can include its translucent shadow. Scan through the
        // opaque client area and title bar to measure the window itself.
        let width = try (0..<bitmap.width).count { try bitmap.rgba(x: $0, y: row)[3] == 255 }
        let height = try (0..<bitmap.height).count { try bitmap.rgba(x: leftX, y: $0)[3] == 255 }
        let measurements = "fixture=\(capture.fixture), scale=\(scale)\n" +
            "PNG=\(bitmap.width)×\(bitmap.height), opaque=\(width)×\(height), left=\(left), right=\(right)"
        print(measurements)
        try artifacts.text(measurements, name: "window-capture-pixels.txt")
        XCTAssertEqual(CGFloat(width), capture.fixture.width * scale, accuracy: 2,
                       "Captured PNG opaque width does not match the fixture")
        XCTAssertEqual(CGFloat(height), capture.fixture.height * scale, accuracy: 2,
                       "Captured PNG opaque height does not match the fixture")
        for (side, actual, expected) in [("left", left, [255, 0, 0]), ("right", right, [0, 0, 255])] {
            for (index, channel) in expected.enumerated() {
                XCTAssertLessThanOrEqual(abs(Int(actual[index]) - channel), 3,
                                         "Wrong fixture color on the \(side): \(actual)")
            }
        }

        try app.input.press("⌃⌥⌘N")
        _ = try settledPanel()
        _ = try required(.panelModeMenu)
        try app.input.press("ESC")
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.app.liveElement(.panel) == nil },
                      "Esc did not close Main after the window capture")

        try app.input.press("⌃⌥⌘P")
        _ = try required(.archiveBack)
        let expectedLabel = "Screenshot \(capture.png.deletingPathExtension().lastPathComponent)"
        let savedInArchive = try waitUntil(timeout: 3) {
            guard let first = try self.app.liveElement(where: { try $0.identifier == "stampo.archive.cell.0" }) else {
                return false
            }
            return try first.first { node in
                try node.attribute(kAXDescriptionAttribute) as? String == expectedLabel
            } != nil
        }
        XCTAssertTrue(savedInArchive, "The first archive cell does not contain \(expectedLabel)")
        try artifacts.text(app.application.debugDescription, name: "window-capture-archive-tree.txt")
        try expectThumbnailDismissed(capture, label: "second")
        // Close via the same collectFiles toggle used to inspect the archive.
        // Esc on the recovered Main panel has already been verified above.
        try app.input.press("⌃⌥⌘P")
        try expectClosed("Second collectFiles hotkey did not close the captured screenshot archive")
        XCTAssertEqual(NSPasteboard.general.changeCount, pasteboardCount, "Window capture changed the pasteboard")
    }

    func testOverlayHotkeysAndEscCancel() throws {
        try app.launch(fixture: true)
        try app.requireScreenRecording()
        try WindowHitTest.requireNoUserNotificationWindow()
        try recordWindowBaseline()
        let (fixture, pid) = try raiseFixture()
        try app.input.move(to: CGPoint(x: fixture.minX + fixture.width / 4, y: fixture.midY))

        // The color HUD retains its hidden panel after the first session.
        // Establish its cache while proving Esc leaves the visible set intact.
        try openAndCancelOverlay("C", pid: pid, label: "color-hud-warmup")
        try recordWindowBaseline(primePanelCache: false)

        for key in ["R", "S", "F", "C"] {
            try openAndCancelOverlay(key, pid: pid, label: "overlay-\(key)")
            expectWindowSetUnchanged()
        }
    }

    private func openAndCancelOverlay(_ key: String, pid: pid_t, label: String) throws {
        let display = CGDisplayBounds(CGMainDisplayID())
        let before = try WindowHitTest.windows().filter { $0.processID == Int(pid) }
        let ids = Set(before.map(\.number))
        try WindowHitTest.requireNoUserNotificationWindow()
        try app.input.press("⌃⌥⌘\(key)")
        var overlay: WindowHitTest.Window?
        XCTAssertTrue(try waitUntil(timeout: 5) {
            try WindowHitTest.requireNoUserNotificationWindow()
            overlay = try WindowHitTest.windows().first {
                $0.processID == Int(pid) && $0.alpha > 0 && !ids.contains($0.number)
                    && WindowHitTest.framesMatch($0.frame, display)
            }
            return overlay != nil
        }, "\(key) did not open a new full-display overlay owned by Stampo")
        let window = try XCTUnwrap(overlay)
        try artifacts.text(window.description, name: "\(label)-open.txt")

        try WindowHitTest.requireNoUserNotificationWindow()
        try app.input.press("ESC")
        XCTAssertTrue(try waitUntil(timeout: 3) {
            try WindowHitTest.requireNoUserNotificationWindow()
            let current = try WindowHitTest.windows().filter { $0.processID == Int(pid) }
            return Set(current.map(\.number)) == ids
        }, "Esc did not remove the \(key) overlay and restore the visible window set")
        try artifacts.text("removed window \(window.number)", name: "\(label)-cancelled.txt")
    }

    private struct WindowCapture {
        let png: URL
        let fixture: CGRect
        let thumbnail: Int
        let observedAt: TimeInterval
    }

    private func captureFixture(excluding existingPNGs: Set<URL>, label: String) throws -> WindowCapture {
        let (fixture, pid) = try raiseFixture()
        let center = CGPoint(x: fixture.midX, y: fixture.midY)
        var onScreenBefore = Set<Int>()
        var diagnostic = ""
        let ownsCaptureTarget = try waitUntil(timeout: 1) {
            let windows = try WindowHitTest.windows()
            let owned = windows.filter { $0.processID == Int(pid) }
            // Match FrontmostWindowResolver's first eligible layer-zero window.
            let target = owned.first { window in
                let frame = window.frame
                return window.layer == 0 && !frame.isEmpty &&
                    (frame.width >= 60 || frame.height >= 60) && frame.width * frame.height >= 3600
            }
            let hit = windows.first {
                $0.alpha > 0 && $0.frame.contains(center) && !WindowHitTest.isSystemAutomationOverlay($0)
            }
            let frontmost = NSWorkspace.shared.frontmostApplication
            diagnostic = "frontmost=\(frontmost?.bundleIdentifier ?? "unknown") PID=\(frontmost?.processIdentifier ?? -1)\n" +
                "fixture=\(fixture), expected PID=\(pid)\n" +
                "capture target=\(target?.description ?? "none")\nfirst hit=\(hit?.description ?? "none")"
            guard frontmost?.processIdentifier == pid, let target, hit?.number == target.number,
                  WindowHitTest.framesMatch(target.frame, fixture) else { return false }
            onScreenBefore = Set(owned.map(\.number))
            return true
        }
        try artifacts.text(diagnostic, name: "window-capture-\(label)-guard.txt")
        XCTAssertTrue(ownsCaptureTarget, "Fixture is not the active owned capture target; G was not sent. \(diagnostic)")
        try WindowHitTest.requireOwnedTarget(at: center, frame: fixture, pid: pid, label: "window-capture-\(label)", artifacts: artifacts)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw E2EFailure("Fixture lost activation during the ownership check; G was not sent")
        }
        try app.input.press("⌃⌥⌘G")

        let captures = app.directory.appendingPathComponent("captures", isDirectory: true)
        var capture: WindowCapture?
        let ready = try waitUntil(timeout: 5) {
            let pngs = try FileManager.default.contentsOfDirectory(at: captures, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "png" && !existingPNGs.contains($0) }
            let newWindows = try WindowHitTest.windows().filter {
                $0.processID == Int(pid) && !onScreenBefore.contains($0.number) && $0.alpha > 0
            }
            guard pngs.count == 1, let png = pngs.first,
                  newWindows.count == 1, let hud = newWindows.first else { return false }
            capture = WindowCapture(png: png, fixture: fixture, thumbnail: hud.number,
                                    observedAt: ProcessInfo.processInfo.systemUptime)
            return true
        }
        XCTAssertTrue(ready, "The \(label) window hotkey did not produce a new PNG and thumbnail within 5 s")
        return try XCTUnwrap(capture)
    }

    private func expectThumbnailDismissed(_ capture: WindowCapture, label: String) throws {
        let dismissed = try waitUntil(timeout: 5) {
            try !WindowHitTest.windows().contains { $0.number == capture.thumbnail }
        }
        XCTAssertTrue(dismissed, "Screenshot thumbnail \(capture.thumbnail) did not go off screen")
        let elapsed = ProcessInfo.processInfo.systemUptime - capture.observedAt
        try artifacts.text("thumbnail=\(capture.thumbnail)\nobserved off screen after \(elapsed) s",
                           name: "window-capture-\(label)-thumbnail.txt")
    }

    @discardableResult
    private func expectPinnedArchive(label: String) throws -> CGRect {
        _ = try required(.archiveBack)
        let frame = try settledPanel()
        XCTAssertNil(try app.liveElement(.panelModeMenu), "collectFiles did not route to Archive")
        let pinned = try waitUntil(timeout: 3) { try self.unpinButton() != nil }
        XCTAssertTrue(pinned, "collectFiles did not expose the existing Unpin panel button")
        try artifacts.text(app.application.debugDescription, name: "\(label)-tree.txt")
        try artifacts.step(label)
        return frame
    }

    private func unpinButton() throws -> AccessibilityNode? {
        try app.liveElement {
            try $0.role == kAXButtonRole && $0.attribute(kAXDescriptionAttribute) as? String == "Unpin panel"
        }
    }

    private func clickFixtureOutsidePanel(frame: CGRect, label: String) throws {
        let (fixtureFrame, pid) = try raiseFixture()
        let point = CGPoint(x: fixtureFrame.midX, y: fixtureFrame.midY)
        XCTAssertFalse(frame.contains(point), "Fixture center must be outside the panel")
        let firstIsFixture = try waitUntil(timeout: 1) {
            let first = try WindowHitTest.windows().first {
                $0.alpha > 0 && $0.frame.contains(point) && !WindowHitTest.isSystemAutomationOverlay($0)
            }
            return first?.processID == Int(pid) && first.map { WindowHitTest.framesMatch($0.frame, fixtureFrame) } == true
        }
        XCTAssertTrue(firstIsFixture, "Fixture was not first after one activate/AXRaise")
        let afterActivation = try settledPanel()
        XCTAssertTrue(WindowHitTest.framesMatch(afterActivation, frame),
                      "Fixture activation changed the panel before outside click: \(frame) -> \(afterActivation)")
        try WindowHitTest.requireOwnedTarget(at: point, frame: fixtureFrame, pid: pid, label: label, artifacts: artifacts)
        try app.input.click(at: point)
    }

    private func raiseFixture() throws -> (CGRect, pid_t) {
        try app.input.park()
        let fixture = try required(.fixture)
        let frame = try XCTUnwrap(fixture.frame, "Fixture has no window frame")
        let pid = try XCTUnwrap(app.processID, "Missing fixture PID")
        app.application.activate()
        let raised = AXUIElementPerformAction(fixture.element, kAXRaiseAction as CFString)
        guard raised == .success else { throw E2EFailure("Fixture AXRaise failed: \(raised.rawValue)") }
        return (frame, pid)
    }

    private func required(_ control: E2EApp.Control) throws -> AccessibilityNode {
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.app.liveElement(control) != nil },
                      "Missing \(control.rawValue); AX errors must throw")
        return try XCTUnwrap(app.liveElement(control))
    }

    private func settledPanel() throws -> CGRect {
        _ = try required(.panel)
        var previous: CGRect?
        var stable = 0
        var result: CGRect?
        let settled = try waitUntil(timeout: 3) {
            guard let frame = try self.app.liveElement(.panel)?.frame, !frame.isEmpty else {
                stable = 0
                return false
            }
            stable = frame == previous ? stable + 1 : 0
            previous = frame
            result = frame
            return stable >= 2
        }
        XCTAssertTrue(settled, "Hotkey panel frame did not settle")
        return try XCTUnwrap(result)
    }

    private func expectClosed(_ message: String) throws {
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.app.liveElement(.panel) == nil }, message)
        expectWindowSetUnchanged()
    }
}
