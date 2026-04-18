import OSLog

/// Central logging namespace. Each category maps to one functional area
/// and appears as a separate stream in Console.app.
///
/// Usage:
///   Log.capture.error("screencapture exited with status \(status)")
///   Log.color.debug("SCShareableContent refreshed")
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.hex000.NotchShot"

    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let capture  = Logger(subsystem: subsystem, category: "capture")
    static let color    = Logger(subsystem: subsystem, category: "color")
    static let metrics  = Logger(subsystem: subsystem, category: "metrics")
    static let panel    = Logger(subsystem: subsystem, category: "panel")
}
