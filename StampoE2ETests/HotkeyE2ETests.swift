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

        // The first capture retains its HUD as one hidden window. Keep the
        // original baseline and require exactly that addition.
        let first = try captureFixture(excluding: [], label: "first")
        try expectThumbnailDismissed(first, label: "first")
        try recordExpectedCachedWindow(first.thumbnail)

        // A second G also checks preSelection was cleared. N can reopen Main
        // even when that state is stale and would mask the blocked second G.
        let capture = try captureFixture(excluding: [first.png], label: "second")
        try expectThumbnailDismissed(capture, label: "second")
        let bitmap = try Files.Bitmap(png: capture.png)
        let scale = try XCTUnwrap(NSScreen.screens.first).backingScaleFactor
        let leftX = bitmap.width / 4
        let row = bitmap.height * 2 / 3
        let left = try bitmap.rgba(x: leftX, y: row)
        let right = try bitmap.rgba(x: bitmap.width * 3 / 4, y: row)
        let cornerAlpha = try bitmap.rgba(x: 0, y: 0)[3]
        // A window PNG can include its translucent shadow. Scan through the
        // opaque client area and title bar to measure the window itself.
        let width = try (0..<bitmap.width).count { try bitmap.rgba(x: $0, y: row)[3] == 255 }
        let height = try (0..<bitmap.height).count { try bitmap.rgba(x: leftX, y: $0)[3] == 255 }
        let measurements = "fixture=\(capture.fixture), scale=\(scale)\n" +
            "PNG=\(bitmap.width)×\(bitmap.height), opaque=\(width)×\(height), corner alpha=\(cornerAlpha), left=\(left), right=\(right)"
        print(measurements)
        try artifacts.text(measurements, name: "window-capture-pixels.txt")
        XCTAssertEqual(CGFloat(width), capture.fixture.width * scale, accuracy: 2,
                       "Captured PNG opaque width does not match the fixture")
        XCTAssertEqual(CGFloat(height), capture.fixture.height * scale, accuracy: 2,
                       "Captured PNG opaque height does not match the fixture")
        XCTAssertGreaterThan(bitmap.width, width, "Captured PNG width has no translucent shadow margin")
        XCTAssertGreaterThan(bitmap.height, height, "Captured PNG height has no translucent shadow margin")
        XCTAssertLessThan(cornerAlpha, 255, "Captured PNG corner is opaque")
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
        // Close via the same collectFiles toggle used to inspect the archive.
        // Esc on the recovered Main panel has already been verified above.
        try app.input.press("⌃⌥⌘P")
        try expectClosed("Second collectFiles hotkey did not close the captured screenshot archive")
        XCTAssertEqual(NSPasteboard.general.changeCount, pasteboardCount, "Window capture changed the pasteboard")
    }

    func testOverlayHotkeysAndEscCancel() throws {
        let pid = try prepareCaptureOverlays()

        for key in ["R", "S", "F"] {
            // A dismissed overlay can still block reentry if its cancellation
            // callback did not reset the capture state.
            for attempt in 1...2 {
                try openAndCancelOverlay(key, pid: pid, label: "overlay-\(key)-\(attempt)")
                expectWindowSetUnchanged()
            }
        }
    }

    func testPipetteDoesNotAccumulateWindows() throws {
        let pid = try prepareCaptureOverlays()
        try openAndCancelOverlay("C", pid: pid, label: "pipette-cycle-1", allowColorHUDCache: true)

        for cycle in 2...4 {
            try openAndCancelOverlay("C", pid: pid, label: "pipette-cycle-\(cycle)")
            expectWindowSetUnchanged()
        }
    }

    func testPipetteEscCancelsAndAddsNothing() throws {
        try app.launch(fixture: true, archive: true)
        try preparePipette()
        try openPipetteArchive()
        let before = try archiveCellIDs()
        XCTAssertFalse(before.isEmpty, "Pipette cancellation requires the seeded archive")
        let first = try archiveColor(at: 0, missing: "The seeded first archive cell is missing")
        try closePipetteArchive()

        let pid = try positionForPipette(fraction: 0.25, label: "esc").pid
        let pasteboardCount = NSPasteboard.general.changeCount
        try openAndCancelOverlay("C", pid: pid, label: "pipette-esc-warmup", allowColorHUDCache: true)
        try openAndCancelOverlay("C", pid: pid, label: "pipette-esc")
        expectWindowSetUnchanged()
        XCTAssertEqual(NSPasteboard.general.changeCount, pasteboardCount, "Esc in the pipette changed the pasteboard")

        try openPipetteArchive()
        XCTAssertEqual(try archiveCellIDs(), before, "Esc in the pipette changed the archive cells")
        XCTAssertEqual(try archiveColor(at: 0, missing: "The first archive cell disappeared after pipette Esc"),
                       first, "Esc in the pipette changed the first archive color")
        try closePipetteArchive()
    }

    func testPipettePicksFixtureColors() throws {
        try app.launch(fixture: true)
        try preparePipette()
        try openPipetteArchive()
        XCTAssertTrue(try archiveCellIDs().isEmpty, "The isolated archive already contains cells before the picks")
        try closePipetteArchive()

        let red = try pickFixtureColor(fraction: 0.25, label: "red", allowColorHUDCache: true)
        let blue = try pickFixtureColor(fraction: 0.75, label: "blue", allowColorHUDCache: false)

        try openPipetteArchive()
        let first = try archiveColor(at: 0, missing: "Pipette did not add a new color entry to the archive")
        let second = try archiveColor(at: 1, missing: "Pipette did not add a second color entry to the archive")
        XCTAssertEqual(try archiveCellIDs(), ["stampo.archive.cell.0", "stampo.archive.cell.1"],
                       "Expected exactly two archive entries after the picks")

        // AutomationModeUI was on screen (alpha 0.25 from CGWindowList). The
        // pipette (ScreenCaptureKit, whole display, excludingWindows: []) read
        // the fixture RGB at the sampled points on 2026-11-21: (255,0,0) and
        // (0,0,255). The mechanism was not measured.
        try expectArchiveColor(first, rgb: [0, 0, 255], from: blue)
        try expectArchiveColor(second, rgb: [255, 0, 0], from: red)
        try closePipetteArchive()
    }

    private struct PipetteSample {
        let label: String
        let point: CGPoint
        let copiedHex: String
        let overlay: WindowHitTest.Window?
    }

    private func preparePipette() throws {
        try app.requireScreenRecording()
        try WindowHitTest.requireNoUserNotificationWindow()
        try app.input.press("⌃⌥⌘N")
        _ = try settledPanel()
        try WindowHitTest.requireNoUserNotificationWindow()
        try app.input.press("⌃⌥⌘N")
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.app.liveElement(.panel) == nil },
                      "Panel cache warmup did not close the panel")
        try recordWindowBaseline(primePanelCache: false)
    }

    private func positionForPipette(fraction: CGFloat, label: String) throws -> (point: CGPoint, pid: pid_t) {
        try WindowHitTest.requireNoUserNotificationWindow()
        let (fixture, pid) = try raiseFixture()
        let point = CGPoint(x: fixture.minX + fixture.width * fraction, y: fixture.maxY - 100)
        _ = try waitUntil(timeout: 2) {
            try WindowHitTest.requireNoUserNotificationWindow()
            let window = try self.firstPipetteHit(at: point)
            return window?.processID == Int(pid) && window.map { WindowHitTest.framesMatch($0.frame, fixture) } == true
        }
        try WindowHitTest.requireOwnedTarget(at: point, frame: fixture, pid: pid,
                                            label: "pipette-fixture-\(label)", artifacts: artifacts)
        try app.input.move(to: point)
        return (point, pid)
    }

    private func firstPipetteHit(at point: CGPoint) throws -> WindowHitTest.Window? {
        try WindowHitTest.windows().first {
            $0.alpha > 0 && $0.frame.contains(point) && !WindowHitTest.isSystemAutomationOverlay($0)
        }
    }

    private func pickFixtureColor(fraction: CGFloat, label: String, allowColorHUDCache: Bool) throws -> PipetteSample {
        let (point, pid) = try positionForPipette(fraction: fraction, label: label)
        let before = try visibleWindowIDs(pid: pid)
        let cursor = try openOverlay("C", pid: pid, label: "pipette-\(label)", excluding: before)
        let hud = try colorHUD(pid: pid, cursor: cursor.number, excluding: before)
        var preview = ""
        XCTAssertTrue(try waitUntil(timeout: 3) {
            try WindowHitTest.requireNoUserNotificationWindow()
            return try self.app.liveElement { node in
                let value = try node.value
                guard self.pipetteRGB(value) != nil else { return false }
                preview = value
                return true
            } != nil
        }, "Pipette HUD did not publish a sampled HEX value at \(point)")

        // Uncover the sample point for WindowServer's ownership check. The
        // real click moves the pointer back before it posts mouse-down.
        try app.input.move(to: CGPoint(x: point.x + 38, y: point.y))
        _ = try waitUntil(timeout: 1) {
            try WindowHitTest.requireNoUserNotificationWindow()
            return try self.firstPipetteHit(at: point)?.number == cursor.number
        }
        let frame = try settledPipetteFrame(cursor, label: label)
        let hit = try WindowHitTest.requireOwnedTarget(at: point, frame: frame, pid: pid,
                                                       label: "pipette-\(label)", artifacts: artifacts, context: "pipette")
        guard hit.number == cursor.number, hit.layer == cursor.layer else {
            throw E2EFailure("Pipette click refused at \(point); expected \(cursor.description), first hit \(hit.description)")
        }
        let film = try WindowHitTest.windows().first {
            WindowHitTest.isSystemAutomationOverlay($0) && $0.frame.contains(point)
        }
        let hex = try clickAndRestoreClipboard(at: point, preview: preview, label: label)
        try artifacts.text("point=\(point), HEX=\(hex), overlay=\(film?.description ?? "no window")",
                           name: "pipette-\(label)-sample.txt")
        try expectVisibleWindows(before, pid: pid, "Pipette pick at \(point) did not restore the visible window set")
        if allowColorHUDCache {
            try recordExpectedCachedWindow(hud.number, name: "pipette-after-pick-expected")
        } else {
            expectWindowSetUnchanged()
        }
        return PipetteSample(label: label, point: point, copiedHex: hex, overlay: film)
    }

    private func settledPipetteFrame(_ cursor: WindowHitTest.Window, label: String) throws -> CGRect {
        let display = CGDisplayBounds(CGMainDisplayID())
        let deadline = Date().addingTimeInterval(3)
        var previous: CGRect?
        var settled: CGRect?
        var readings: [String] = []
        repeat {
            try WindowHitTest.requireNoUserNotificationWindow()
            let frame = try WindowHitTest.windows().first {
                $0.processID == cursor.processID && $0.number == cursor.number && $0.layer == cursor.layer && $0.alpha > 0
            }?.frame
            readings.append(frame.map { String(describing: $0) } ?? "missing")
            if let frame, WindowHitTest.framesMatch(frame, display) {
                if frame == previous {
                    settled = frame
                    break
                }
                previous = frame
            } else {
                previous = nil
            }
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.1)))
        } while Date() < deadline

        let diagnostic = "\(label): PID=\(cursor.processID), ID=\(cursor.number), layer=\(cursor.layer), " +
            "display=\(display) ±1 pt, frame readings 100 ms apart: \(readings.joined(separator: " -> "))"
        try artifacts.text(diagnostic, name: "pipette-\(label)-frame-readings.txt")
        guard let settled else {
            throw E2EFailure("Pipette frame did not settle within 3 s; no click was sent. \(diagnostic)")
        }
        return settled
    }

    private func clickAndRestoreClipboard(at point: CGPoint, preview: String, label: String) throws -> String {
        let pasteboard = NSPasteboard.general
        let snapshot = try ClipboardSnapshot()
        let count = pasteboard.changeCount
        var copied = ""
        do {
            try WindowHitTest.requireNoUserNotificationWindow()
            try app.input.click(at: point)
            guard try waitUntil(timeout: 3, {
                try WindowHitTest.requireNoUserNotificationWindow()
                guard pasteboard.changeCount != count, let hex = pasteboard.string(forType: .string),
                      self.pipetteRGB(hex) != nil else { return false }
                copied = hex
                return true
            }) else { throw E2EFailure("Pipette did not copy a HEX value at \(point)") }
        } catch {
            let restored = try snapshot.restoreIfChanged(allowing: preview)
            try artifacts.text(restored, name: "clipboard-pipette-\(label).txt")
            throw error
        }
        let delta = pasteboard.changeCount - count
        let restored = try snapshot.restoreIfChanged(allowing: delta == 1 || delta == 2 ? copied : preview)
        try artifacts.text(restored, name: "clipboard-pipette-\(label).txt")
        XCTAssertTrue(restored.hasPrefix("restored known Stampo payload"), "Pipette clipboard was not restored: \(restored)")
        return copied
    }

    private func openPipetteArchive() throws {
        try WindowHitTest.requireNoUserNotificationWindow()
        try app.input.press("⌃⌥⌘P")
        _ = try required(.archiveBack)
        _ = try settledPanel()
    }

    private func closePipetteArchive() throws {
        try WindowHitTest.requireNoUserNotificationWindow()
        try app.input.press("⌃⌥⌘P")
        try expectClosed("Second collectFiles hotkey did not close the pipette archive")
    }

    private func archiveCellIDs() throws -> Set<String> {
        var pending = [try required(.panel)]
        var identifiers: Set<String> = []
        var visited = 0
        while let node = pending.popLast() {
            visited += 1
            guard visited <= 2000 else { throw E2EFailure("Archive AX traversal exceeded the 2000-node limit") }
            let id = try node.identifier
            if id.hasPrefix("stampo.archive.cell.") { identifiers.insert(id) }
            pending.append(contentsOf: try node.children)
        }
        return identifiers
    }

    private func archiveColor(at index: Int, missing: String) throws -> String {
        let identifier = "stampo.archive.cell.\(index)"
        let hasCell = try waitUntil(timeout: 3) {
            try WindowHitTest.requireNoUserNotificationWindow()
            return try self.app.liveElement { try $0.identifier == identifier } != nil
        }
        XCTAssertTrue(hasCell, missing)
        let cell = try XCTUnwrap(app.liveElement { try $0.identifier == identifier })
        let frame = try XCTUnwrap(cell.frame, "Missing frame for \(identifier)")
        // The color's existing label can be revealed by hover, with no click.
        try app.input.move(to: CGPoint(x: frame.midX, y: frame.midY))
        var hex = ""
        let found = try waitUntil(timeout: 3) {
            try WindowHitTest.requireNoUserNotificationWindow()
            guard let cell = try self.app.liveElement(where: { try $0.identifier == identifier }) else {
                return false
            }
            return try cell.first { node in
                guard let text = try node.attribute(kAXDescriptionAttribute) as? String,
                      text.hasPrefix("Color ") else { return false }
                hex = String(text.dropFirst("Color ".count))
                return true
            } != nil
        }
        XCTAssertTrue(found, missing)
        return hex
    }

    private func pipetteRGB(_ hex: String) -> [Int]? {
        guard hex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil,
              let rgb = Int(hex.dropFirst(), radix: 16) else { return nil }
        return [(rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255]
    }

    private func expectArchiveColor(_ hex: String, rgb expected: [Int], from sample: PipetteSample) throws {
        let actual = pipetteRGB(hex)
        let film = sample.overlay.map { "alpha=\($0.alpha), frame=\($0.frame)" } ?? "no window"
        let diagnostic = "\(sample.label) point=\(sample.point), expected RGB=\(expected), " +
            "actual RGB=\(actual.map { String(describing: $0) } ?? "unreadable (\(hex))"), " +
            "tolerance=±3 per channel, AutomationModeUI: \(film), clipboard=\(sample.copiedHex)"
        try artifacts.text(diagnostic, name: "pipette-\(sample.label)-archive-color.txt")
        XCTAssertTrue(actual.map { zip($0, expected).allSatisfy { abs($0 - $1) <= 3 } } == true, diagnostic)
    }

    private func prepareCaptureOverlays() throws -> pid_t {
        try app.launch(fixture: true)
        try app.requireScreenRecording()
        try WindowHitTest.requireNoUserNotificationWindow()
        try recordWindowBaseline()
        let (fixture, pid) = try raiseFixture()
        try app.input.move(to: CGPoint(x: fixture.minX + fixture.width / 4, y: fixture.midY))
        return pid
    }

    private func openAndCancelOverlay(_ key: String, pid: pid_t, label: String,
                                      allowColorHUDCache: Bool = false) throws {
        let ids = try visibleWindowIDs(pid: pid)
        let overlay = try openOverlay(key, pid: pid, label: label, excluding: ids)
        let hud = try allowColorHUDCache ? colorHUD(pid: pid, cursor: overlay.number, excluding: ids) : nil
        if let hud { try artifacts.text(hud.description, name: "\(label)-hud.txt") }

        try WindowHitTest.requireNoUserNotificationWindow()
        try app.input.press("ESC")
        try expectVisibleWindows(ids, pid: pid, "Esc did not remove the \(key) overlay and restore the visible window set (\(label))")
        try artifacts.text("removed window \(overlay.number)", name: "\(label)-cancelled.txt")
        if let hud {
            do {
                try recordExpectedCachedWindow(hud.number, name: "pipette-after-cycle-1-expected")
            } catch {
                throw E2EFailure("\(label): \(error)")
            }
        }
    }

    private func visibleWindowIDs(pid: pid_t) throws -> Set<Int> {
        Set(try WindowHitTest.windows().filter { $0.processID == Int(pid) }.map(\.number))
    }

    private func expectVisibleWindows(_ ids: Set<Int>, pid: pid_t, _ message: String,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(try waitUntil(timeout: 3) {
            try WindowHitTest.requireNoUserNotificationWindow()
            return try self.visibleWindowIDs(pid: pid) == ids
        }, message, file: file, line: line)
    }

    private func colorHUD(pid: pid_t, cursor: Int, excluding ids: Set<Int>) throws -> WindowHitTest.Window {
        var hud: WindowHitTest.Window?
        XCTAssertTrue(try waitUntil(timeout: 3) {
            try WindowHitTest.requireNoUserNotificationWindow()
            hud = try WindowHitTest.windows().first {
                $0.processID == Int(pid) && $0.alpha > 0 && $0.layer == NSWindow.Level.statusBar.rawValue
                    && $0.number != cursor && !ids.contains($0.number)
            }
            return hud != nil
        }, "Pipette did not show its color HUD")
        return try XCTUnwrap(hud)
    }

    private func openOverlay(_ key: String, pid: pid_t, label: String,
                             excluding ids: Set<Int>) throws -> WindowHitTest.Window {
        let display = CGDisplayBounds(CGMainDisplayID())
        let overlayLayer = key == "C" ? Int(CGWindowLevelForKey(.cursorWindow)) - 2 : NSWindow.Level.screenSaver.rawValue
        try WindowHitTest.requireNoUserNotificationWindow()
        try app.input.press("⌃⌥⌘\(key)")
        var overlay: WindowHitTest.Window?
        XCTAssertTrue(try waitUntil(timeout: 5) {
            try WindowHitTest.requireNoUserNotificationWindow()
            overlay = try WindowHitTest.windows().first {
                $0.processID == Int(pid) && $0.alpha > 0 && !ids.contains($0.number)
                    && $0.layer == overlayLayer
            }
            return overlay != nil
        }, "\(key) did not open a new full-display overlay owned by Stampo (\(label))")
        let window = try XCTUnwrap(overlay)
        try artifacts.text(window.description, name: "\(label)-first-frame.txt")

        // The app requests the display frame. WindowServer can report an
        // intermediate frame when the new window first appears.
        func currentOverlay() throws -> WindowHitTest.Window? {
            try WindowHitTest.requireNoUserNotificationWindow()
            return try WindowHitTest.windows().first {
                $0.number == window.number && $0.processID == Int(pid) && $0.alpha > 0
            }
        }
        var matchingOverlay: WindowHitTest.Window?
        let reachedDisplay = try waitUntil(timeout: 1) {
            guard let current = try currentOverlay(), WindowHitTest.framesMatch(current.frame, display) else { return false }
            matchingOverlay = current
            return true
        }
        if !reachedDisplay {
            var previousFrame: CGRect?
            var stableFrame: CGRect?
            _ = try waitUntil(timeout: 0.5) {
                let frame = try currentOverlay()?.frame
                if let frame, frame == previousFrame { stableFrame = frame }
                previousFrame = frame
                return stableFrame != nil
            }
            let diagnostic = "\(label): expected \(display) ±1 pt within 1 s; first=\(window.frame), "
                + "last=\(String(describing: previousFrame)), stable=\(String(describing: stableFrame))"
            try artifacts.text(diagnostic, name: "\(label)-frame-timeout.txt")
            throw E2EFailure(diagnostic)
        }
        let matched = try XCTUnwrap(matchingOverlay)
        try artifacts.text(matched.description, name: "\(label)-open.txt")
        return matched
    }

    private struct WindowCapture {
        let png: URL
        let fixture: CGRect
        let thumbnail: Int
        let observedAt: TimeInterval
    }

    private func captureFixture(excluding existingPNGs: Set<URL>, label: String) throws -> WindowCapture {
        try WindowHitTest.requireNoUserNotificationWindow()
        let (fixture, pid) = try raiseFixture()
        let center = CGPoint(x: fixture.midX, y: fixture.midY)
        var diagnostic = ""
        let ownsCaptureTarget = try waitUntil(timeout: 1) {
            let windows = try WindowHitTest.windows()
            let target = try self.firstCaptureWindow(pid: pid)
            let hit = windows.first {
                $0.alpha > 0 && $0.frame.contains(center) && !WindowHitTest.isSystemAutomationOverlay($0)
            }
            let frontmost = NSWorkspace.shared.frontmostApplication
            diagnostic = "frontmost=\(frontmost?.bundleIdentifier ?? "unknown") PID=\(frontmost?.processIdentifier ?? -1)\n" +
                "fixture=\(fixture), expected PID=\(pid)\n" +
                "capture target=\(target?.description ?? "none")\nfirst hit=\(hit?.description ?? "none")"
            guard frontmost?.processIdentifier == pid, let target, hit?.number == target.number,
                  WindowHitTest.framesMatch(target.frame, fixture) else { return false }
            return true
        }
        try artifacts.text(diagnostic, name: "window-capture-\(label)-guard.txt")
        XCTAssertTrue(ownsCaptureTarget, "Fixture is not the active owned capture target; G was not sent. \(diagnostic)")
        try WindowHitTest.requireOwnedTarget(at: center, frame: fixture, pid: pid, label: "window-capture-\(label)", artifacts: artifacts)
        try WindowHitTest.requireNoUserNotificationWindow()
        let onScreenBefore = Set(try WindowHitTest.windows().filter { $0.processID == Int(pid) }.map(\.number))
        let target = try firstCaptureWindow(pid: pid)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let target, WindowHitTest.framesMatch(target.frame, fixture) else {
            throw E2EFailure("Fixture is no longer the first capture window of the active app; G was not sent")
        }
        try app.input.press("⌃⌥⌘G")

        let captures = app.directory.appendingPathComponent("captures", isDirectory: true)
        var capture: WindowCapture?
        let ready = try waitUntil(timeout: 5) {
            try WindowHitTest.requireNoUserNotificationWindow()
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

    private func firstCaptureWindow(pid: pid_t) throws -> WindowHitTest.Window? {
        // Use the same WindowServer options, ordering and size gate as
        // FrontmostWindowResolver.
        try WindowHitTest.windows(options: [.optionOnScreenOnly, .excludeDesktopElements]).first { window in
            let frame = window.frame
            return window.processID == Int(pid) && window.layer == 0 && window.isOnScreen && !frame.isEmpty
                && (frame.width >= 60 || frame.height >= 60) && frame.width * frame.height >= 3600
        }
    }

    private func expectThumbnailDismissed(_ capture: WindowCapture, label: String) throws {
        // AppSettings.thumbnailDismissDelay defaults to 3 s. ScreenshotThumbnailHUD
        // starts its fade after that delay. Observe from the first visible sample.
        let remaining = max(0, 5 - (ProcessInfo.processInfo.systemUptime - capture.observedAt))
        let dismissed = try waitUntil(timeout: remaining) {
            try WindowHitTest.requireNoUserNotificationWindow()
            return try !WindowHitTest.windows().contains { $0.number == capture.thumbnail }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - capture.observedAt
        try artifacts.text("thumbnail=\(capture.thumbnail)\nobserved off screen after \(elapsed) s",
                           name: "window-capture-\(label)-thumbnail.txt")
        XCTAssertTrue(dismissed, "Screenshot thumbnail \(capture.thumbnail) did not go off screen")
        XCTAssertGreaterThanOrEqual(elapsed, 3, "Screenshot thumbnail disappeared before its 3 s delay")
        XCTAssertLessThanOrEqual(elapsed, 5, "Screenshot thumbnail remained on screen longer than 5 s")
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
