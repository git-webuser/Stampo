import Foundation
import Testing
@testable import Stampo

@MainActor
@Suite struct PanelTransitionCoordinatorTests {
    @Test func generationInvalidatesDelayedWork() {
        let coordinator = PanelTransitionCoordinator()
        let token = coordinator.currentToken()
        #expect(coordinator.matches(token))

        coordinator.bumpGeneration()
        #expect(!coordinator.matches(token))
    }

    @Test func rebindingInvalidatesOldWindowCallbacks() {
        let coordinator = PanelTransitionCoordinator()
        let token = coordinator.currentToken()

        coordinator.rebind()

        #expect(!coordinator.matches(token))
        #expect(coordinator.generation == token.generation)
        #expect(coordinator.bindingID != token.bindingID)
    }
}
