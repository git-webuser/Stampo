import Foundation
import Vision

// MARK: - ScanRecognition

/// The panel's unified scanner: one Vision pass over the selected region that
/// finds every QR/barcode payload and all readable text. Payloads are treated
/// strictly as plain text — never opened, linkified, or fetched.
enum ScanRecognition {
    /// One recognized finding with its normalized Vision bounding box
    /// (origin bottom-left).
    struct Candidate {
        var string: String
        var box: CGRect
    }

    struct Result: Equatable {
        /// Every barcode payload, in visual order (top-to-bottom, then
        /// left-to-right within a row).
        var codePayloads: [String]
        /// Recognized text lines outside any code's box, joined with newlines.
        var text: String
        /// Every finding in visual order — what lands on the clipboard.
        var clipboardText: String

        var isEmpty: Bool { codePayloads.isEmpty && text.isEmpty }
    }

    static func scan(in imageURL: URL) throws -> Result {
        try scan(using: VNImageRequestHandler(url: imageURL))
    }

    static func scan(in cgImage: CGImage) throws -> Result {
        try scan(using: VNImageRequestHandler(cgImage: cgImage, options: [:]))
    }

    private static func scan(using handler: VNImageRequestHandler) throws -> Result {
        // Leave `symbologies` at Vision's default so QR and the other barcode
        // formats supported by the running macOS release are all recognized.
        let barcodes = VNDetectBarcodesRequest()
        let text = TextRecognition.makeRequest()
        try handler.perform([barcodes, text])

        var codes: [Candidate] = []
        for observation in (barcodes.results ?? []).sorted(by: { $0.confidence > $1.confidence }) {
            guard let payload = observation.payloadStringValue, !payload.isEmpty else { continue }
            // The same symbol is occasionally reported twice (e.g. under two
            // symbologies); keep the higher-confidence observation.
            let isDuplicate = codes.contains {
                $0.string == payload && $0.box.intersects(observation.boundingBox)
            }
            if !isDuplicate {
                codes.append(Candidate(string: payload, box: observation.boundingBox))
            }
        }

        let textLines: [Candidate] = (text.results ?? []).compactMap { observation in
            guard let line = observation.topCandidates(1).first?.string else { return nil }
            return Candidate(string: line, box: observation.boundingBox)
        }

        return assemble(codes: codes, textLines: textLines)
    }

    /// Pure assembly, split from Vision for testability: drops text found
    /// inside a code's box (the QR pattern itself OCRs as garbage), orders
    /// everything visually, and builds the combined clipboard string.
    static func assemble(codes: [Candidate], textLines: [Candidate]) -> Result {
        let keptText = textLines.filter { line in
            !codes.contains { code in
                let overlap = line.box.intersection(code.box)
                guard !overlap.isNull else { return false }
                let lineArea = line.box.width * line.box.height
                return lineArea > 0 && overlap.width * overlap.height > 0.5 * lineArea
            }
        }

        // Visual order: group into rows top-to-bottom (Vision boxes are
        // bottom-left-origin, so higher midY first), left-to-right within a
        // row. The greedy row grouping keeps the sort deterministic — a raw
        // "overlap ? minX : midY" comparator is not a strict weak ordering.
        struct Item {
            var candidate: Candidate
            var isCode: Bool
        }
        let items = (codes.map { Item(candidate: $0, isCode: true) }
                     + keptText.map { Item(candidate: $0, isCode: false) })
            .sorted { $0.candidate.box.midY > $1.candidate.box.midY }

        var rows: [[Item]] = []
        for item in items {
            if let anchor = rows.last?.first,
               sameRow(anchor.candidate.box, item.candidate.box) {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        let ordered = rows.flatMap { row in
            row.sorted { $0.candidate.box.minX < $1.candidate.box.minX }
        }

        return Result(
            codePayloads: ordered.filter(\.isCode).map(\.candidate.string),
            text: ordered.filter { !$0.isCode }.map(\.candidate.string).joined(separator: "\n"),
            clipboardText: ordered.map(\.candidate.string).joined(separator: "\n")
        )
    }

    /// Two boxes share a visual row when their vertical overlap exceeds half
    /// of the shorter box's height.
    private static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap > 0.5 * min(a.height, b.height)
    }
}
