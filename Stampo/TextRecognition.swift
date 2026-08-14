import Vision

/// Single source of truth for the app's text recognition (OCR) configuration,
/// shared by the panel's unified Scan action (`ScanRecognition`) and the
/// editor's region-recognize tool (`EditorView`). Keeping the recognition level
/// and language hints here means adding a UI language only touches one place.
nonisolated enum TextRecognition {
    /// Language hints biasing toward the app's shipped UI languages.
    /// `automaticallyDetectsLanguage` still allows others to be recognized.
    static let languages = ["en-US", "ru-RU"]

    /// A recognize-text request configured consistently across the app. Returns
    /// a fresh request per call (a `VNRecognizeTextRequest` is single-use with
    /// `VNImageRequestHandler.perform`).
    nonisolated static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = languages
        return request
    }
}
