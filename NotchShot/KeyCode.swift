/// Virtual key codes used for keyboard event handling across the app.
/// Values come from Carbon / HIToolbox Events.h (kVK_* constants).
enum KeyCode {
    static let escape:      UInt16 = 53   // kVK_Escape
    static let arrowUp:     UInt16 = 126  // kVK_UpArrow
    static let arrowDown:   UInt16 = 125  // kVK_DownArrow
    static let arrowLeft:   UInt16 = 123  // kVK_LeftArrow
    static let arrowRight:  UInt16 = 124  // kVK_RightArrow
    /// ANSI "F" key — cycles the color format in the color picker HUD.
    static let f:           UInt16 = 3    // kVK_ANSI_F
}
