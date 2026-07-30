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
        /// Tray entries in visual order (topmost first): each code payload on
        /// its own, plus the whole recognized text as one entry placed where
        /// its topmost line falls. Callers add these in reverse so the tray —
        /// which inserts at the top — lists the visually-topmost finding first.
        var trayEntries: [String] = []

        var isEmpty: Bool { codePayloads.isEmpty && text.isEmpty }
    }

    static func scan(in imageURL: URL, joinsLines: Bool = false) throws -> Result {
        try scan(using: VNImageRequestHandler(url: imageURL), joinsLines: joinsLines)
    }

    static func scan(in cgImage: CGImage, joinsLines: Bool = false) throws -> Result {
        try scan(using: VNImageRequestHandler(cgImage: cgImage, options: [:]),
                 joinsLines: joinsLines)
    }

    private static func scan(using handler: VNImageRequestHandler,
                             joinsLines: Bool) throws -> Result {
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

        return assemble(codes: codes, textLines: textLines, joinsLines: joinsLines)
    }

    /// Pure assembly, split from Vision for testability: drops text found
    /// inside a code's box (the QR pattern itself OCRs as garbage), orders
    /// everything visually, and builds the combined clipboard string.
    ///
    /// `joinsLines` glues the recognized text into one paragraph. It only ever
    /// merges runs of text: a barcode payload is a value, not prose, so it
    /// always keeps a line of its own even between joined text.
    static func assemble(codes: [Candidate], textLines: [Candidate],
                         joinsLines: Bool = false) -> Result {
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

        let join = { (lines: [String]) in
            joinsLines ? joinWrappedLines(lines) : lines.joined(separator: "\n")
        }
        let text = join(ordered.filter { !$0.isCode }.map(\.candidate.string))

        // Clipboard: consecutive text lines form a run that `join` collapses;
        // codes break the run and stay on their own line. Without joining this
        // is the same "everything on its own line" string as before.
        var chunks: [String] = []
        var run: [String] = []
        for item in ordered {
            if item.isCode {
                if !run.isEmpty { chunks.append(join(run)); run = [] }
                chunks.append(item.candidate.string)
            } else {
                run.append(item.candidate.string)
            }
        }
        if !run.isEmpty { chunks.append(join(run)) }

        // Tray order = visual order: each code on its own, and the whole text
        // blob once, at the position of its topmost line.
        var trayEntries: [String] = []
        var textInserted = false
        for item in ordered {
            if item.isCode {
                trayEntries.append(item.candidate.string)
            } else if !textInserted {
                trayEntries.append(text)
                textInserted = true
            }
        }

        return Result(
            codePayloads: ordered.filter(\.isCode).map(\.candidate.string),
            text: text,
            clipboardText: chunks.joined(separator: "\n"),
            trayEntries: trayEntries
        )
    }

    /// Glues lines wrapped by the layout back into one paragraph.
    ///
    /// A line ending in a hyphen is joined without a space but keeps the
    /// hyphen: at a line break it is ambiguous between a wrap hyphen
    /// ("пере-/нос") and a real one ("кто-/то"), and keeping it loses nothing
    /// a reader can't fix, while dropping it would silently weld two words.
    /// A soft hyphen is unambiguous — it exists only to mark a wrap — so it
    /// goes. Everything else joins with a single space.
    static func joinWrappedLines(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard !result.isEmpty else { result = trimmed; continue }
            switch result.last {
            case "\u{00AD}": result.removeLast(); result += trimmed
            case "-":        result += trimmed
            default:         result += " " + trimmed
            }
        }
        return result
    }

    /// Two boxes share a visual row when their vertical overlap exceeds half
    /// of the shorter box's height.
    private static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap > 0.5 * min(a.height, b.height)
    }
}
