import Testing
@testable import Stampo

@Suite struct PanelStateTests {

    @Test func inFlightStatesSuppressAutoHide() {
        #expect(!PanelState.transitioning(to: .archive).allowsAutoHide)
        #expect(!PanelState.transitioning(to: .main).allowsAutoHide)
        #expect(!PanelState.countdown.allowsAutoHide)
        #expect(!PanelState.preSelection(.selection).allowsAutoHide)
        #expect(!PanelState.preSelection(.window).allowsAutoHide)
    }

    @Test func restingStatesAllowAutoHide() {
        #expect(PanelState.hidden.allowsAutoHide)
        #expect(PanelState.showing.allowsAutoHide)
        #expect(PanelState.main.allowsAutoHide)
        #expect(PanelState.archive.allowsAutoHide)
        #expect(PanelState.hiding.allowsAutoHide)
        #expect(PanelState.stale(reason: .sleep).allowsAutoHide)
    }

    @Test(arguments: [StaleReason.sleep, .spaceChange, .displayChange])
    func staleIsStaleForEveryReason(reason: StaleReason) {
        #expect(PanelState.stale(reason: reason).isStale)
    }

    @Test func nonStaleStatesAreNotStale() {
        #expect(!PanelState.hidden.isStale)
        #expect(!PanelState.showing.isStale)
        #expect(!PanelState.main.isStale)
        #expect(!PanelState.transitioning(to: .archive).isStale)
        #expect(!PanelState.archive.isStale)
        #expect(!PanelState.hiding.isStale)
        #expect(!PanelState.countdown.isStale)
        #expect(!PanelState.preSelection(.selection).isStale)
    }
}

/// Esc is registered application-wide while the panel holds it, so both halves
/// of the decision — whether to hold the key at all, and what a press does —
/// are pure functions on the state rather than branches buried in the handler.
@Suite struct PanelEscapeTests {

    /// Esc and the back chevron climb one ladder, so it is checked once here
    /// and each control's own last rung separately below.
    @Test func theLadderRunsInnermostFirst() {
        #expect(archiveUnwindStep(hasExpandedStack: true, isSelecting: true) == .collapseStack)
        #expect(archiveUnwindStep(hasExpandedStack: true, isSelecting: false) == .collapseStack)
        #expect(archiveUnwindStep(hasExpandedStack: false, isSelecting: true) == .exitSelection)
        #expect(archiveUnwindStep(hasExpandedStack: false, isSelecting: false) == .leaveArchive)
    }

    @Test func expandedStackSwallowsTheFirstEscape() {
        #expect(PanelState.archive.escapeAction(hasExpandedStack: true, isSelecting: false)
                == .collapseStack)
    }

    @Test func escapeClosesThePanelOnceNothingIsExpanded() {
        #expect(PanelState.archive.escapeAction(hasExpandedStack: false, isSelecting: false)
                == .hidePanel)
    }

    @Test func selectionIsTheLayerBetweenTheStackAndThePanel() {
        #expect(PanelState.archive.escapeAction(hasExpandedStack: false, isSelecting: true)
                == .exitSelection)
    }

    /// One press, one layer, innermost first: a stack expanded inside a
    /// selection collapses before the mode is touched, so neither press has to
    /// undo two things at once.
    @Test func theStackUnwindsBeforeTheSelectionDoes() {
        #expect(PanelState.archive.escapeAction(hasExpandedStack: true, isSelecting: true)
                == .collapseStack)
    }

    /// A stack can only be expanded inside the archive, but the flag outlives
    /// the route by an instant while the archive morphs away — the press must
    /// close the panel then, not collapse something the user can no longer see.
    /// The selection flag is cleared on the same close and outlives it the same
    /// way, so it is read under the same guard.
    @Test(arguments: [PanelState.main, .showing, .countdown, .transitioning(to: .main)])
    func onlyTheArchiveUnwindsInsteadOfClosing(state: PanelState) {
        #expect(state.escapeAction(hasExpandedStack: true, isSelecting: false) == .hidePanel)
        #expect(state.escapeAction(hasExpandedStack: false, isSelecting: true) == .hidePanel)
    }

    @Test(arguments: [PanelState.showing, .main, .archive, .countdown])
    func visibleStatesHoldTheHotkey(state: PanelState) {
        #expect(state.wantsEscapeHotkey(isSharePickerOpen: false))
    }

    /// .hiding is already on its way out, and the rest have no panel to act on.
    @Test(arguments: [PanelState.hidden, .hiding, .transitioning(to: .archive),
                      .preSelection(.selection), .stale(reason: .sleep)])
    func everythingElseReleasesIt(state: PanelState) {
        #expect(!state.wantsEscapeHotkey(isSharePickerOpen: false))
    }

    /// The share sheet is our own window: holding the hotkey would eat the Esc
    /// meant for the sheet and close the panel it hangs off instead.
    @Test(arguments: [PanelState.showing, .main, .archive, .countdown])
    func anOpenShareSheetTakesTheHotkeyBack(state: PanelState) {
        #expect(!state.wantsEscapeHotkey(isSharePickerOpen: true))
    }
}
