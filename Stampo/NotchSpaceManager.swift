import Foundation

/// Owns the single dedicated CGS space the notch panel lives in.
///
/// The space sits at the maximum absolute level, above the normal user Spaces.
/// A window placed in it is decoupled from Spaces/Mission Control compositing,
/// which fixes both the panel sliding during a Space swipe and the inter-Space
/// band crossing it in Mission Control. The space must outlive every panel
/// window, so it's held by this process-lifetime singleton.
final class NotchSpaceManager {
    static let shared = NotchSpaceManager()
    let notchSpace: CGSSpace

    private init() {
        notchSpace = CGSSpace(level: Int(Int32.max))
    }
}
