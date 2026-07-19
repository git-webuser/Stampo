import AppKit
import CoreImage
import Testing
@testable import Stampo

@Suite struct ScanRecognitionAssembleTests {

    private func code(_ s: String, _ box: CGRect) -> ScanRecognition.Candidate {
        ScanRecognition.Candidate(string: s, box: box)
    }

    @Test func emptyInputProducesEmptyResult() {
        let result = ScanRecognition.assemble(codes: [], textLines: [])
        #expect(result.isEmpty)
        #expect(result.clipboardText == "")
    }

    @Test func textInsideACodeBoxIsDropped() {
        // The QR pattern itself OCRs as garbage; a line mostly covered by the
        // code's box must not survive, while a line outside it must.
        let qr = code("payload", CGRect(x: 0.1, y: 0.4, width: 0.4, height: 0.5))
        let garbage = code("|||l1", CGRect(x: 0.15, y: 0.6, width: 0.2, height: 0.05))
        let caption = code("Caption below", CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.08))

        let result = ScanRecognition.assemble(codes: [qr], textLines: [garbage, caption])
        #expect(result.codePayloads == ["payload"])
        #expect(result.text == "Caption below")
        #expect(result.clipboardText == "payload\nCaption below")
    }

    @Test func partiallyOverlappingTextSurvives() {
        // Under half of the line lies inside the code's box → kept.
        let qr = code("payload", CGRect(x: 0.0, y: 0.5, width: 0.3, height: 0.4))
        let line = code("wide line", CGRect(x: 0.2, y: 0.6, width: 0.6, height: 0.06))

        let result = ScanRecognition.assemble(codes: [qr], textLines: [line])
        #expect(result.text == "wide line")
    }

    @Test func findingsAreOrderedTopToBottomThenLeftToRight() {
        // Vision boxes are bottom-left-origin: higher midY = visually higher.
        let left = code("left QR", CGRect(x: 0.05, y: 0.55, width: 0.25, height: 0.3))
        let right = code("right QR", CGRect(x: 0.65, y: 0.57, width: 0.25, height: 0.3))
        let title = code("Title", CGRect(x: 0.3, y: 0.9, width: 0.4, height: 0.07))
        let footer = code("Footer", CGRect(x: 0.3, y: 0.05, width: 0.4, height: 0.07))

        let result = ScanRecognition.assemble(
            codes: [right, left],
            textLines: [footer, title]
        )
        #expect(result.codePayloads == ["left QR", "right QR"])
        #expect(result.text == "Title\nFooter")
        #expect(result.clipboardText == "Title\nleft QR\nright QR\nFooter")
    }
}

// MARK: - HUD outcome mapping

@Suite struct ScanOutcomeTests {

    private func result(codes: [String], text: String) -> ScanRecognition.Result {
        ScanRecognition.Result(
            codePayloads: codes,
            text: text,
            clipboardText: (codes + (text.isEmpty ? [] : [text])).joined(separator: "\n")
        )
    }

    @Test @MainActor func textOnlyShowsPlainCopied() {
        let outcome = ScanCaptureCoordinator.outcome(for: result(codes: [], text: "abc"))
        guard case .copied = outcome else {
            Issue.record("expected .copied, got \(outcome)")
            return
        }
    }

    @Test @MainActor func singleCodeAloneKeepsPayloadPreviewToast() {
        let outcome = ScanCaptureCoordinator.outcome(for: result(codes: ["p1"], text: ""))
        guard case .codeCopied(let payload) = outcome, payload == "p1" else {
            Issue.record("expected .codeCopied(p1), got \(outcome)")
            return
        }
    }

    @Test @MainActor func singleCodeWithTextReportsCounts() {
        let outcome = ScanCaptureCoordinator.outcome(for: result(codes: ["p1"], text: "abc"))
        guard case .scanCopied(let codes, let includesText) = outcome,
              codes == 1, includesText else {
            Issue.record("expected .scanCopied(1, true), got \(outcome)")
            return
        }
    }

    @Test @MainActor func multipleCodesWithoutTextReportCountOnly() {
        let outcome = ScanCaptureCoordinator.outcome(for: result(codes: ["p1", "p2"], text: ""))
        guard case .scanCopied(let codes, let includesText) = outcome,
              codes == 2, !includesText else {
            Issue.record("expected .scanCopied(2, false), got \(outcome)")
            return
        }
    }
}

// MARK: - Vision end-to-end

@Suite struct ScanRecognitionVisionTests {

    /// One synthetic image, one Vision pass: the QR payload and the caption
    /// both come back, in visual order, with the QR's own pattern not leaking
    /// into the recognized text.
    @Test @MainActor func qrAboveCaptionScansToOrderedPlainText() throws {
        let payload = "https://stampo.invalid/scan?value=plain-text"
        let filter = try #require(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let qrImage = try #require(filter.outputImage)
            .transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        let qrCG = try #require(context.createCGImage(qrImage, from: qrImage.extent))

        let size = NSSize(width: 600, height: 480)
        let canvas = NSImage(size: size)
        canvas.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSImage(cgImage: qrCG, size: .zero)
            .draw(in: NSRect(x: 200, y: 200, width: 200, height: 200))
        ("The quick brown fox" as NSString).draw(
            at: NSPoint(x: 120, y: 60),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 36, weight: .bold),
                .foregroundColor: NSColor.black,
            ]
        )
        canvas.unlockFocus()
        var proposed = NSRect(origin: .zero, size: size)
        let cgImage = try #require(
            canvas.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        )

        let result = try ScanRecognition.scan(in: cgImage)
        #expect(result.codePayloads == [payload])
        #expect(result.text == "The quick brown fox")
        #expect(result.clipboardText == "\(payload)\nThe quick brown fox")
    }
}
