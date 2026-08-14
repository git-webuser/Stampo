import Foundation

/// Owns the lifecycle identity used by delayed panel work. The controller
/// remains the public facade, but transition generation and window rebinding
/// now have one small state owner that can be exercised without constructing a
/// real `NSPanel`.
@MainActor
final class PanelTransitionCoordinator {
    private(set) var generation: Int = 0
    private(set) var bindingID = UUID()

    @discardableResult
    func bumpGeneration() -> Int {
        generation &+= 1
        return generation
    }

    func currentToken() -> PanelTransitionToken {
        PanelTransitionToken(generation: generation, bindingID: bindingID)
    }

    func matches(_ token: PanelTransitionToken) -> Bool {
        generation == token.generation && bindingID == token.bindingID
    }

    func invalidate() {
        bumpGeneration()
    }

    /// A newly-created panel is a different lifecycle even when the logical
    /// transition generation happens to be unchanged.
    func rebind() {
        bindingID = UUID()
    }
}
