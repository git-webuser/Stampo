import AppKit

// MARK: - ScreenshotSoundPlayer

/// Plays the system screenshot shutter sound.
/// Tries the named sound first (works across macOS versions without path coupling),
/// then falls back to known file paths for macOS 12–14, then to NSSound.beep().
enum ScreenshotSoundPlayer {
    static func play() {
        if let sound = NSSound(named: "Screen Capture") {
            sound.play()
            return
        }
        let candidates: [String] = [
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aiff",
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/screenshot.aiff",
            "/System/Library/Library/Sounds/Screen Capture.aiff",
            "/System/Library/Sounds/Glass.aiff"
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let sound = NSSound(contentsOfFile: path, byReference: true) {
                sound.play()
                return
            }
        }
        NSSound.beep()
    }
}
