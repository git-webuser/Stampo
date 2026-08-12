/// Virtual key codes used for keyboard event handling across the app.
/// Values come from Carbon / HIToolbox Events.h (kVK_* constants).
enum KeyCode {
    static let escape:      UInt16 = 53   // kVK_Escape
    static let arrowUp:     UInt16 = 126  // kVK_UpArrow
    static let arrowDown:   UInt16 = 125  // kVK_DownArrow
    static let arrowLeft:   UInt16 = 123  // kVK_LeftArrow
    static let arrowRight:  UInt16 = 124  // kVK_RightArrow
    /// ANSI "F" key — cycles the color format in the color picker HUD, where
    /// it stands for Format.
    static let f:           UInt16 = 3    // kVK_ANSI_F
    /// Cycles the target language on the scan overlay, ⇧⇥ backwards. Tab
    /// rather than a letter because there is no letter to stand for
    /// "the next one", and nothing is typed on a selection overlay for it to
    /// take away.
    static let tab:         UInt16 = 48   // kVK_Tab
}
