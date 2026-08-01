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
