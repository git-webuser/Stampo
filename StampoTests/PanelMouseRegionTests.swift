import Testing
@testable import Stampo

@Suite struct PanelMouseRegionTests {

    private func ignores(onDrawn: Bool, buttons: Bool, archiveDrag: Bool) -> Bool {
        PanelMouseRegion.ignoresMouse(onDrawnContent: onDrawn, buttonsDown: buttons,
                                      archiveDragInFlight: archiveDrag)
    }

    // MARK: No archive drag — the rules from before

    @Test func idlePointerOverTheDrawingIsTaken() {
        #expect(!ignores(onDrawn: true, buttons: false, archiveDrag: false))
    }

    @Test func idlePointerOverTheTransparentPartPassesThrough() {
        #expect(ignores(onDrawn: false, buttons: false, archiveDrag: false))
    }

    @Test func aHeldButtonKeepsThePointerOverTheTransparentPart() {
        // A plain press on the panel, or a Finder drag on its way in: neither
        // may lose the window halfway.
        #expect(!ignores(onDrawn: false, buttons: true, archiveDrag: false))
    }

    @Test func aHeldButtonOverTheDrawingIsTaken() {
        #expect(!ignores(onDrawn: true, buttons: true, archiveDrag: false))
    }

    // MARK: Archive drag in flight

    @Test func archiveDragOverTheTransparentPartPassesThrough() {
        // The reported bug: released here, the drop landed on the panel's own
        // window, which refuses its own drags, and the drag snapped back.
        #expect(ignores(onDrawn: false, buttons: true, archiveDrag: true))
    }

    @Test func archiveDragOverTheDrawingIsStillTaken() {
        #expect(!ignores(onDrawn: true, buttons: true, archiveDrag: true))
    }

    @Test func archiveDragFollowsTheBorderBothWays() {
        // Out over the strip, back onto the archive, out again.
        let path: [(onDrawn: Bool, ignores: Bool)] = [
            (true, false), (false, true), (true, false), (false, true)
        ]
        for step in path {
            #expect(ignores(onDrawn: step.onDrawn, buttons: true, archiveDrag: true) == step.ignores)
        }
    }

    @Test func archiveDragFlagWithTheButtonAlreadyUpStillFollowsThePointer() {
        // The flag can outlive the button for a moment before the cell reports
        // the end of the drag.
        #expect(ignores(onDrawn: false, buttons: false, archiveDrag: true))
        #expect(!ignores(onDrawn: true, buttons: false, archiveDrag: true))
    }
}
