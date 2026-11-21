import AppKit
import ApplicationServices
import XCTest

@MainActor
final class ArchiveEscapeE2ETests: E2ETestCase {
    // PanelTiming and hideExpandedThenMain/hideMainPanel in NotchPanelController:
    // 0.12 s dissolve + 0.22 s morph + 0.22 s frame animation + 0.34 s margin.
    private let archiveHideBound: TimeInterval = 0.9
    private var clipboard: ClipboardSnapshot?
    private var clickNumber = 0
    private var changeCountBeforeCommandClick: Int?

    override func setUpWithError() throws {
        try super.setUpWithError()
        clipboard = try ClipboardSnapshot()
    }

    override func tearDownWithError() throws {
        // Restore before common teardown can report a failure. Keep every
        // process/window/AX/log/crash/input invariant from E2ETestCase.
        var restorationError: Error?
        do {
            if let disposition = try clipboard?.restoreIfChanged() {
                print("Pasteboard restoration: \(disposition)")
                try artifacts.text(disposition, name: "pasteboard-restoration.txt")
            }
        } catch { restorationError = error }
        try super.tearDownWithError()
        if let restorationError { throw restorationError }
    }

    func testArchiveStackClickToleratesTwoPointJitter() throws {
        try app.launch(archive: true)
        try WindowHitTest.requireNoUserNotificationWindow()
        try app.input.press("⌃⌥⌘N")
        _ = try settledPanel()
        try app.input.press("⌃⌥⌘N")
        XCTAssertTrue(try waitUntil(timeout: 3) { try app.liveElement(.panel) == nil },
                      "Panel cache warmup did not close the panel")
        try recordWindowBaseline(primePanelCache: false)

        try WindowHitTest.requireNoUserNotificationWindow()
        try app.input.press("⌃⌥⌘N")
        try click("stampo.panel.archiveToggle")
        let stack = "stampo.archive.cell.4"
        let initial = try settledPanel()
        try expectArchiveState(expanded: false, selecting: false, frame: initial, label: "before-jitter")
        let (start, window) = try guardedPressTarget(stack)
        let jitterEnd = CGPoint(x: start.x + 2, y: start.y)
        XCTAssertTrue(window.frame.contains(jitterEnd), "Jitter must end inside the archive panel")
        try app.input.clickWithJitter(from: start, to: jitterEnd)
        XCTAssertTrue(try waitUntil(timeout: 3) {
            try WindowHitTest.requireNoUserNotificationWindow()
            return try app.liveElement { try $0.identifier == "stampo.archive.stack.member.0" } != nil
        }, "stack did not expand after a 2 pt jitter click")
        let expanded = try observeRetainedPanel(missingMessage: "Jitter click closed the archive panel")
        try expectSameArchiveWindow(window, at: expanded)
        try expectArchiveState(expanded: true, selecting: false, frame: expanded, label: "two-point-click")

        try WindowHitTest.requireNoUserNotificationWindow()
        try app.input.press("ESC")
        let collapsed = try observeRetainedPanel(missingMessage: "Esc closed the panel instead of collapsing the stack")
        try expectSameArchiveWindow(window, at: collapsed)
        try expectArchiveState(expanded: false, selecting: false, frame: collapsed, label: "before-drag")
        let cellsBeforeDrag = try archiveCellIdentifiers()
        XCTAssertEqual(cellsBeforeDrag.count, 5, "Expected five archive fixture cells before dragging")

        let (dragStart, dragWindow) = try guardedPressTarget(stack)
        let dragEnd = CGPoint(x: dragStart.x + 16, y: dragStart.y)
        XCTAssertTrue(dragWindow.frame.contains(dragEnd), "Drag must be released over the archive panel")
        let pasteboard = NSPasteboard(name: .drag)
        let beforeDrag = pasteboard.changeCount
        try app.input.holdMouse(at: dragStart)
        try app.input.dragHeldMouse(from: dragStart, to: dragEnd, steps: 8)
        let dragStarted = try waitUntil(timeout: 1) {
            try WindowHitTest.requireNoUserNotificationWindow()
            return pasteboard.changeCount != beforeDrag
        }
        try app.input.releaseMouse(at: dragEnd)
        XCTAssertTrue(dragStarted, "16 pt pull did not start an AppKit drag session")
        let distances = "2 pt: \(start) -> \(jitterEnd)\n16 pt: \(dragStart) -> \(dragEnd)\n"
            + "drag pasteboard: \(beforeDrag) -> \(pasteboard.changeCount)"
        try artifacts.text(distances, name: "stack-gesture-distances.txt")

        let openedDuringObservation = try waitUntil(timeout: archiveHideBound) {
            try WindowHitTest.requireNoUserNotificationWindow()
            guard try app.liveElement(.panel) != nil else { throw E2EFailure("Drag closed the archive panel") }
            return try app.liveElement { try $0.identifier.hasPrefix("stampo.archive.stack.member.") } != nil
        }
        XCTAssertFalse(openedDuringObservation, "stack expanded after a 16 pt drag")
        let afterDrag = try settledPanel(missingMessage: "Missing archive panel after drag")
        XCTAssertTrue(WindowHitTest.framesMatch(afterDrag, dragWindow.frame), "Drag changed the archive panel frame")
        try expectSameArchiveWindow(window, at: afterDrag)
        try expectArchiveState(expanded: false, selecting: false, frame: afterDrag, label: "sixteen-point-drag")
        let cellsAfterDrag = try archiveCellIdentifiers()
        XCTAssertEqual(cellsAfterDrag, cellsBeforeDrag, "Dropping the stack on its own panel changed the archive cells")
        try artifacts.text("cells before: \(cellsBeforeDrag.sorted())\ncells after: \(cellsAfterDrag.sorted())",
                           name: "archive-cells-after-self-drop.txt")
        try WindowHitTest.requireNoUserNotificationWindow()
        try app.input.press("ESC")
        XCTAssertTrue(try waitUntil(timeout: 3) { try app.liveElement(.panel) == nil },
                      "Esc did not close the collapsed archive after drag")
        expectWindowSetUnchanged()
    }

    private func expectSameArchiveWindow(_ window: WindowHitTest.Window, at frame: CGRect) throws {
        let live = try WindowHitTest.windows().first { $0.number == window.number && $0.processID == window.processID }
        let actual = try XCTUnwrap(live, "Archive panel with ID \(window.number) is no longer visible")
        XCTAssertTrue(WindowHitTest.framesMatch(actual.frame, frame),
                      "Archive panel AX frame differs from WindowServer: \(frame) vs \(actual.frame)")
    }

    private func archiveCellIdentifiers() throws -> Set<String> {
        var pending = [try required(E2EApp.Control.panel.rawValue)]
        var identifiers: Set<String> = []
        var visited = 0
        while let node = pending.popLast() {
            visited += 1
            guard visited <= 2000 else { throw E2EFailure("Archive AX traversal exceeded the 2000-node limit") }
            let identifier = try node.identifier
            if identifier.hasPrefix("stampo.archive.cell.") { identifiers.insert(identifier) }
            pending.append(contentsOf: try node.children)
        }
        return identifiers
    }

    func testEscUnwindsOneLayerPerPress() throws {
        let frame = try prepareArchive()

        try app.input.press("ESC")
        try observeArchiveState(expanded: false, selecting: true, frame: frame, label: "esc-1")
        try app.input.press("ESC")
        try observeArchiveState(expanded: false, selecting: false, frame: frame, label: "esc-2")
        try app.input.press("ESC")
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.app.liveElement(.panel) == nil },
                      "Third Esc did not close the panel")
        expectWindowSetUnchanged()
        try artifacts.step("esc-3-closed")
        let count = try XCTUnwrap(changeCountBeforeCommandClick)
        XCTAssertEqual(NSPasteboard.general.changeCount, count, "⌘-click copied to the pasteboard")
        try artifacts.text("unchanged=\(NSPasteboard.general.changeCount == count)", name: "command-click-pasteboard.txt")
    }

    func testBackUnwindsTheSameLadder() throws {
        let frame = try prepareArchive()
        try artifacts.text(app.application.debugDescription, name: "before-back-tree.txt")
        let backFrame = try XCTUnwrap(required("stampo.archive.back").frame)
        try artifacts.text("back=\(backFrame)\npanel=\(frame)", name: "back-target-frame.txt")
        XCTAssertEqual(backFrame.width, 32, accuracy: 1, "Back target must match its explicit 32 pt cell, not the archive container")
        XCTAssertEqual(backFrame.height, 24, accuracy: 1, "Back target must match its explicit 24 pt cell")
        try click("stampo.archive.back")
        try observeArchiveState(expanded: false, selecting: true, frame: frame, label: "back-1")
        try click("stampo.archive.back")
        try observeArchiveState(expanded: false, selecting: false, frame: frame, label: "back-2")
        try click("stampo.archive.back")
        let mainFrame = try observeRetainedPanel(
            missingMessage: "Missing stampo.panel.window at back-3: Main should remain visible"
        )
        _ = try required(E2EApp.Control.panelModeMenu.rawValue)
        XCTAssertNil(try app.liveElement(.archiveBack), "Third Back did not leave the archive")
        XCTAssertNil(try app.liveElement(.archiveSelection), "Third Back left selection active")
        try artifacts.text("archive=\(frame)\nmain=\(mainFrame)", name: "back-3-frames.txt")
        try artifacts.step("back-3-main-still-visible")
        // Cleanup is a separate real hotkey, after Main was observed alive.
        try app.input.press("⌃⌥⌘N")
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.app.liveElement(.panel) == nil }, "Cleanup hotkey did not close Main")
        expectWindowSetUnchanged()
    }

    func testEscClosesMenuBeforeUnwinding() throws {
        let frame = try prepareArchive()
        try click(E2EApp.Control.archiveColorFormat.rawValue)
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.visibleMenu != nil }, "Archive color-format menu did not open")
        try artifacts.step("archive-menu-open")
        try app.input.press("ESC")
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.visibleMenu == nil }, "First Esc did not close the archive menu")
        try observeArchiveState(expanded: true, selecting: true, frame: frame, label: "menu-esc-1-layers-retained",
                                missingPanel: "First Esc closed the panel together with the archive menu")
        try app.input.press("ESC")
        try observeArchiveState(expanded: false, selecting: true, frame: frame, label: "menu-esc-2-stack-collapsed")
        try app.input.press("ESC")
        try observeArchiveState(expanded: false, selecting: false, frame: frame, label: "menu-esc-3-selection-exited")
        try app.input.press("ESC")
        XCTAssertTrue(try waitUntil(timeout: 3) { try self.app.liveElement(.panel) == nil }, "Fourth Esc did not close the panel after the menu and layers")
        expectWindowSetUnchanged()
        try artifacts.step("menu-esc-4-panel-closed")
    }

    private var visibleMenu: AccessibilityNode? {
        get throws {
            try app.liveElement { try $0.role == kAXMenuRole && !($0.frame?.isEmpty ?? true) }
        }
    }

    private func prepareArchive() throws -> CGRect {
        try app.launch(archive: true)
        try recordWindowBaseline()
        try app.input.press("⌃⌥⌘N")
        _ = try settledPanel()
        try click("stampo.panel.archiveToggle")
        _ = try required("stampo.archive.back")
        for index in 0..<5 { _ = try required("stampo.archive.cell.\(index)") }
        // A plain stack click expands; Command-clicking a COLOR leaf selects
        // without invoking its ordinary Copy action (archiveTapIntent).
        try click("stampo.archive.cell.4")
        for index in 0..<3 { _ = try required("stampo.archive.stack.member.\(index)") }
        let color = try required("stampo.archive.cell.0")
        let colorFrame = try XCTUnwrap(color.frame)
        // The existing Color label is shown on hover. Reveal it by moving over
        // our AX cell before asserting its identity; no click has been sent.
        try app.input.move(to: CGPoint(x: colorFrame.midX, y: colorFrame.midY))
        let labelVisible = try waitUntil(timeout: 1) {
            let cell = try self.required("stampo.archive.cell.0")
            return try cell.first { node in
                try node.attribute(kAXDescriptionAttribute) as? String == "Color #FF6B4A"
            } != nil
        }
        XCTAssertTrue(labelVisible, "Cell 0 is not the expected Color #FF6B4A leaf before Command-click")
        guard labelVisible else { throw E2EFailure("Command-click target is not the expected color leaf") }
        try artifacts.text(app.application.debugDescription, name: "before-command-click-tree.txt")
        try artifacts.text("Color #FF6B4A", name: "command-click-color-label.txt")
        changeCountBeforeCommandClick = NSPasteboard.general.changeCount
        try click("stampo.archive.cell.0", command: true)
        let frame = try settledPanel()
        try expectArchiveState(expanded: true, selecting: true, frame: frame, label: "prepared")

        return frame
    }

    private func required(_ identifier: String) throws -> AccessibilityNode {
        let found = try waitUntil(timeout: 3) { try self.app.liveElement { try $0.identifier == identifier } != nil }
        XCTAssertTrue(found, "Missing \(identifier); failed AX reads must throw")
        return try XCTUnwrap(app.liveElement { try $0.identifier == identifier })
    }

    private func settledPanel(missingMessage: String? = nil) throws -> CGRect {
        if missingMessage == nil { _ = try required(E2EApp.Control.panel.rawValue) }
        var previous: CGRect?
        var stable = 0
        var frame: CGRect?
        let deadline = Date().addingTimeInterval(3)
        repeat {
            let panel = try app.liveElement(.panel)
            if let missingMessage { XCTAssertNotNil(panel, missingMessage) }
            frame = try panel?.frame
            if let current = frame, !current.isEmpty {
                stable = current == previous ? stable + 1 : 0
                previous = current
                if stable >= 2 { return current }
            } else { stable = 0 }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        XCTFail("Panel frame did not settle in two consecutive 100 ms probes")
        throw E2EFailure("Panel frame did not settle: \(String(describing: frame))")
    }

    private func click(_ identifier: String, command: Bool = false) throws {
        let (point, _) = try guardedPressTarget(identifier)
        if command { try app.input.commandClick(at: point) }
        else { try app.input.click(at: point) }
        // Both mouse-down monitors defer handling to a Task, which reads the
        // current pointer position. Leaving immediately can classify this
        // inside click as outside. Keep the pointer here until AX confirms
        // the result because the race depends on main-thread timing.
    }

    private func guardedPressTarget(_ identifier: String) throws -> (CGPoint, WindowHitTest.Window) {
        // Controls can move within an unchanged panel frame during a morph.
        // Require the target's own frame to settle before choosing its center.
        let frame = try settledPanel()
        var previousTarget: CGRect?
        var settledTarget: CGRect?
        let deadline = Date().addingTimeInterval(3)
        repeat {
            let node = try app.liveElement { try $0.identifier == identifier }
            let current = try node?.frame
            if let current, !current.isEmpty, current == previousTarget {
                settledTarget = current
                break
            }
            previousTarget = current
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        let target = try XCTUnwrap(settledTarget, "Hit target \(identifier) did not settle across two 100 ms reads")
        let point = CGPoint(x: target.midX, y: target.midY)
        let pid = try XCTUnwrap(app.processID, "Missing bound PID before a panel click")
        // Approach the target only after the unchanged ownership gate. The
        // cursor has its own WindowServer window; leave it at another point
        // inside our panel while reading the target's front-to-back list.
        let away = CGPoint(x: point.x + 48 < frame.maxX ? point.x + 48 : point.x - 48, y: point.y)
        XCTAssertTrue(frame.contains(away))
        try WindowHitTest.requireNoUserNotificationWindow()
        try app.input.move(to: away)
        _ = try waitUntil(timeout: 1) {
            let first = try WindowHitTest.windows().first {
                $0.alpha > 0 && $0.frame.contains(point) && !WindowHitTest.isSystemAutomationOverlay($0)
            }
            return first?.processID == Int(pid) && first.map { WindowHitTest.framesMatch($0.frame, frame) } == true
        }
        clickNumber += 1
        try WindowHitTest.requireNoUserNotificationWindow()
        let window = try WindowHitTest.requireOwnedTarget(at: point, frame: frame, pid: pid,
                                                          label: "archive-\(clickNumber)", artifacts: artifacts, context: "panel")
        return (point, window)
    }

    private func observeArchiveState(expanded: Bool, selecting: Bool, frame: CGRect, label: String,
                                     missingPanel: String? = nil) throws {
        let current = try observeRetainedPanel(
            missingMessage: missingPanel ?? "Missing stampo.panel.window at \(label): the panel closed while a layer should remain"
        )
        XCTAssertTrue(WindowHitTest.framesMatch(current, frame), "\(label): surviving panel changed frame: \(frame) -> \(current)")
        try expectArchiveState(expanded: expanded, selecting: selecting, frame: current, label: label)
    }

    private func observeRetainedPanel(missingMessage: String) throws -> CGRect {
        let started = ProcessInfo.processInfo.systemUptime
        let disappeared = try waitUntil(timeout: archiveHideBound) { try self.app.liveElement(.panel) == nil }
        if disappeared {
            print("Archive panel disappeared after \(ProcessInfo.processInfo.systemUptime - started) s of observation")
            XCTFail(missingMessage)
            throw E2EFailure(missingMessage)
        }
        return try settledPanel(missingMessage: missingMessage)
    }

    private func expectArchiveState(expanded: Bool, selecting: Bool, frame: CGRect, label: String) throws {
        _ = try required("stampo.archive.back")
        XCTAssertNil(try app.liveElement(.panelModeMenu), "\(label): archive returned to Main")
        for index in 0..<3 {
            let member = try app.liveElement { try $0.identifier == "stampo.archive.stack.member.\(index)" }
            XCTAssertEqual(member != nil, expanded, "\(label): stack member \(index) has wrong visibility")
        }
        let selection = try app.liveElement(.archiveSelection)
        XCTAssertEqual(selection != nil, selecting, "\(label): selection mode has wrong state")
        if selecting {
            let count = try XCTUnwrap(selection).value
            XCTAssertEqual(count, "1", "\(label): selected color was lost")
            let cell = try required("stampo.archive.cell.0")
            let mark = try XCTUnwrap(cell.first { try $0.identifier == "stampo.archive.selectionMark" }, "Selected color has no AX selection mark")
            XCTAssertEqual(try mark.value, "Selected", "\(label): color selection mark lost its value")
        }
        try artifacts.text("expanded=\(expanded)\nselecting=\(selecting)\nframe=\(frame)", name: "\(label)-state.txt")
        try artifacts.step(label)
    }
}
