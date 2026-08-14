import Foundation

/// Sendable result of preparing an editor share. URLs are preferred because
/// they preserve the user's filename; bytes are the in-memory fallback when a
/// temporary staging write fails.
nonisolated struct PreparedSharePayload: Sendable {
    let fileURL: URL?
    let data: Data?
}
