import Testing
@testable import Stampo

@Suite struct PanelStateTests {

    @Test func inFlightStatesSuppressAutoHide() {
        #expect(!PanelState.transitioning(to: .archive).allowsAutoHide)
        #expect(!PanelState.transitioning(to: .main).allowsAutoHide)
        #expect(!PanelState.countdown.allowsAutoHide)
        // A scrolling capture is raised by the app too: the pointer is in the
        // window being scrolled, not on the strip, and the strip must not
        // close itself under the capture.
        #expect(!PanelState.scrollCapture.allowsAutoHide)
        // The wait is raised by the app, not by the pointer — which is
        // therefore nowhere near it. Left to the ordinary "mouse left" rule
        // the panel would close itself in the middle of the translation it
        // opened to report.
        #expect(!PanelState.waiting.allowsAutoHide)
        #expect(!PanelState.preSelection(.selection).allowsAutoHide)
        #expect(!PanelState.preSelection(.window).allowsAutoHide)
    }

    @Test func restingStatesAllowAutoHide() {
        #expect(PanelState.hidden.allowsAutoHide)
        #expect(PanelState.showing.allowsAutoHide)
        #expect(PanelState.main.allowsAutoHide)
        #expect(PanelState.archive.allowsAutoHide)
        #expect(PanelState.translate.allowsAutoHide)
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
        #expect(!PanelState.scrollCapture.isStale)
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
        #expect(PanelState.archive.escapeAction(
            hasExpandedStack: true, isSelecting: false,
            translateCameFromArchive: false) == .collapseStack)
    }

    @Test func escapeClosesThePanelOnceNothingIsExpanded() {
        #expect(PanelState.archive.escapeAction(
            hasExpandedStack: false, isSelecting: false,
            translateCameFromArchive: false) == .hidePanel)
    }

    @Test func selectionIsTheLayerBetweenTheStackAndThePanel() {
        #expect(PanelState.archive.escapeAction(
            hasExpandedStack: false, isSelecting: true,
            translateCameFromArchive: false) == .exitSelection)
    }

    /// One press, one layer, innermost first: a stack expanded inside a
    /// selection collapses before the mode is touched, so neither press has to
    /// undo two things at once.
    @Test func theStackUnwindsBeforeTheSelectionDoes() {
        #expect(PanelState.archive.escapeAction(
            hasExpandedStack: true, isSelecting: true,
            translateCameFromArchive: false) == .collapseStack)
    }

    /// Reading an archive entry in the Translator is a layer over the archive,
    /// the way an expanded stack is: the first press puts it back.
    @Test func aPreviewOpenedFromTheArchiveGoesBackToIt() {
        #expect(PanelState.translate.escapeAction(
            hasExpandedStack: false, isSelecting: false,
            translateCameFromArchive: true) == .backToArchive)
    }

    /// A translation raised over nothing has no archive to return to — the
    /// press closes the panel, as it does everywhere else.
    @Test func aTranslationRaisedOnItsOwnClosesThePanel() {
        #expect(PanelState.translate.escapeAction(
            hasExpandedStack: false, isSelecting: false,
            translateCameFromArchive: false) == .hidePanel)
    }

    /// A stack can only be expanded inside the archive, but the flag outlives
    /// the route by an instant while the archive morphs away — the press must
    /// close the panel then, not collapse something the user can no longer see.
    /// The selection flag is cleared on the same close and outlives it the same
    /// way, so it is read under the same guard.
    @Test(arguments: [PanelState.main, .showing, .countdown, .scrollCapture, .transitioning(to: .main)])
    func onlyTheArchiveUnwindsInsteadOfClosing(state: PanelState) {
        #expect(state.escapeAction(
            hasExpandedStack: true, isSelecting: false,
            translateCameFromArchive: false) == .hidePanel)
        #expect(state.escapeAction(
            hasExpandedStack: false, isSelecting: true,
            translateCameFromArchive: false) == .hidePanel)
    }

    @Test(arguments: [PanelState.showing, .main, .archive, .translate, .countdown, .waiting])
    func visibleStatesHoldTheHotkey(state: PanelState) {
        #expect(state.wantsEscapeHotkey(isSharePickerOpen: false))
    }

    /// .hiding is already on its way out, and the rest have no panel to act on.
    @Test(arguments: [PanelState.hidden, .hiding, .transitioning(to: .archive),
                      .preSelection(.selection), .stale(reason: .sleep)])
    func everythingElseReleasesIt(state: PanelState) {
        #expect(!state.wantsEscapeHotkey(isSharePickerOpen: false))
    }

    /// The strip is on screen, but Esc belongs to the capture session: a
    /// hotkey the panel held here would shadow the session's and close the
    /// strip without telling the capture it was over.
    @Test func theScrollingStripLeavesEscToTheSession() {
        #expect(!PanelState.scrollCapture.wantsEscapeHotkey(isSharePickerOpen: false))
    }

    /// ⇥ is only worth claiming where the header has a list to step through.
    @Test(arguments: [PanelState.archive, .translate])
    func theTwoRoutesWithAListHoldTheCycleKey(state: PanelState) {
        #expect(state.wantsCycleHotkey(scrollModeSelected: false))
        #expect(state.wantsCycleHotkey(scrollModeSelected: true))
    }

    /// Main has one thing to step through, and only in Scrolling: the
    /// direction. In any other mode the key is not the panel's.
    @Test func mainHoldsTheCycleKeyOnlyInTheScrollingMode() {
        #expect(PanelState.main.wantsCycleHotkey(scrollModeSelected: true))
        #expect(!PanelState.main.wantsCycleHotkey(scrollModeSelected: false))
    }

    /// The view's half of the same rule: which route has something to step
    /// through. Together with the state's, the pointer being on the panel and
    /// the setting being on, that is the whole condition for holding ⇥.
    @Test func routesStepThroughSomethingOnlyWhereThereIsSomething() {
        #expect(NotchPanelRoute.archive.cyclesSomething(scrollModeSelected: false))
        #expect(NotchPanelRoute.translate.cyclesSomething(scrollModeSelected: false))
        #expect(NotchPanelRoute.main.cyclesSomething(scrollModeSelected: true))
        #expect(!NotchPanelRoute.main.cyclesSomething(scrollModeSelected: false))
        #expect(!NotchPanelRoute.cdwn.cyclesSomething(scrollModeSelected: true))
    }

    /// Everything else hands it straight back. This is the dangerous half: a
    /// registered hotkey consumes ⇥ for every app on the machine, and the
    /// panel can be pinned open for hours.
    @Test(arguments: [PanelState.hidden, .showing, .main, .hiding, .countdown,
                      .scrollCapture, .waiting, .transitioning(to: .translate),
                      .preSelection(.selection), .stale(reason: .sleep)])
    func everyOtherStateHandsTheCycleKeyBack(state: PanelState) {
        #expect(!state.wantsCycleHotkey(scrollModeSelected: false))
        // Not even in Scrolling: that mode's ⇥ is Main's alone.
        if case .main = state { return }
        #expect(!state.wantsCycleHotkey(scrollModeSelected: true))
    }

    /// The share sheet is our own window: holding the hotkey would eat the Esc
    /// meant for the sheet and close the panel it hangs off instead.
    @Test(arguments: [PanelState.showing, .main, .archive, .countdown])
    func anOpenShareSheetTakesTheHotkeyBack(state: PanelState) {
        #expect(!state.wantsEscapeHotkey(isSharePickerOpen: true))
    }

    /// One strip, two errands: it was built for a translation and now also
    /// carries a save. Only the glyph differs — which is the whole reason it
    /// could be reused, since every morph around it already existed.
    @Test func theWaitStripSaysWhatItIsWaitingFor() {
        #expect(PanelWait.translating.systemImage == "translate")
        #expect(PanelWait.saving.systemImage != PanelWait.translating.systemImage)
        #expect(PanelWait.saved.systemImage != PanelWait.saving.systemImage)

        // A spinner is for something that is still happening.
        #expect(PanelWait.translating.isWorking)
        #expect(PanelWait.saving.isWorking)
        #expect(!PanelWait.saved.isWorking)

        // And only the finished one waits to be read: a save can be over in
        // eighty milliseconds, and a strip that appears and leaves inside a
        // tenth of a second is a flicker rather than an answer.
        #expect(PanelWait.saved.hold > 0.3)
        #expect(PanelWait.translating.hold == 0)
        #expect(PanelWait.saving.hold == 0)
    }

    /// Two closes of one panel — the close button and the click on the notch
    /// land together — leave a hide running when the next show starts. Its
    /// animation reports as the show begins, with a token that is no longer
    /// current, and ordering the window out then hid the new panel while its
    /// state stayed on screen.
    @Test(arguments: [PanelState.showing, .main, .archive, .translate, .countdown,
                      .scrollCapture, .waiting, .transitioning(to: .main)])
    func anOvertakenHideLeavesAShownPanelAlone(state: PanelState) {
        #expect(state.wantsWindowOnScreen)
        #expect(state.sparesWindowFromHideCompletion(tokenIsCurrent: false))
    }

    /// While the state still stands for a hidden panel, the second report may
    /// order the window out again: the panel is meant to be gone, and that is
    /// what it did before.
    @Test(arguments: [PanelState.hidden, .hiding, .preSelection(.window),
                      .stale(reason: .spaceChange)])
    func anOvertakenHideStillClosesAHiddenPanel(state: PanelState) {
        #expect(!state.wantsWindowOnScreen)
        #expect(!state.sparesWindowFromHideCompletion(tokenIsCurrent: false))
    }

    /// A hide that still owns the panel finishes as it always did, in any state.
    @Test(arguments: [PanelState.hidden, .showing, .main, .archive, .translate, .hiding,
                      .countdown, .scrollCapture, .waiting, .transitioning(to: .archive),
                      .preSelection(.selection), .stale(reason: .sleep)])
    func aCurrentHideAlwaysFinishes(state: PanelState) {
        #expect(!state.sparesWindowFromHideCompletion(tokenIsCurrent: true))
    }
}
