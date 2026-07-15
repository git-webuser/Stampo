import AppKit
import CoreImage
import Testing
@testable import Stampo

@Suite struct CodeRecognitionTests {
    @Test func qrPayloadRoundTripsThroughVisionAsPlainText() throws {
        let payload = "https://stampo.invalid/scan?value=plain-text"
        let filter = try #require(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let qrImage = try #require(filter.outputImage)
            .transformed(by: CGAffineTransform(scaleX: 10, y: 10))

        let context = CIContext()
        let cgImage = try #require(context.createCGImage(qrImage, from: qrImage.extent))
        #expect(try CodeRecognition.payload(in: cgImage) == payload)
        let png = try #require(
            NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stampo-code-recognition-\(UUID().uuidString).png")
        try png.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try CodeRecognition.payload(in: url) == payload)
    }
}
