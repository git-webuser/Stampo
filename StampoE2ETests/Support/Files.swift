import Foundation
import CoreGraphics
import ImageIO

struct E2EFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum Files {
    static func folder(_ parent: URL, _ name: String) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    struct Bitmap {
        let width: Int
        let height: Int
        private let bytes: [UInt8]

        init(png: URL) throws {
            guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
                throw E2EFailure("Cannot decode PNG with its embedded ICC profile: \(png.path)")
            }
            let width = image.width
            let height = image.height
            self.width = width
            self.height = height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            // Based on StampoTests/ProbeSupport.swift, Probe.bitmap. Drawing
            // the profiled source into an explicit sRGB context converts ICC;
            // reading NSBitmapImageRep.colorAt alone does not do that reliably.
            let converted = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4, space: srgb,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                                | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.setRenderingIntent(.relativeColorimetric)
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard converted else { throw E2EFailure("Cannot convert PNG to sRGB: \(png.path)") }
            bytes = pixels
        }

        /// Pixel coordinates count down from the top-left, independent of Retina.
        func rgba(x: Int, y: Int) throws -> [UInt8] {
            guard (0..<width).contains(x), (0..<height).contains(y) else {
                throw E2EFailure("Pixel (\(x),\(y)) outside \(width)×\(height)")
            }
            let offset = (y * width + x) * 4
            return Array(bytes[offset..<(offset + 4)])
        }

        func matches(x: Int, y: Int, rgb: [UInt8], tolerance: Int = 2) throws -> Bool {
            guard rgb.count == 3, tolerance >= 0 else { throw E2EFailure("RGB requires three channels and a nonnegative tolerance") }
            return try zip(rgba(x: x, y: y).prefix(3), rgb).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
        }
    }

    struct CommandResult {
        let status: Int32
        let output: String
        let error: String
    }

    static func run(_ executable: String, _ arguments: [String], in folder: URL,
                    timeout: TimeInterval = 10) throws -> CommandResult {
        let prefix = UUID().uuidString
        let out = folder.appendingPathComponent("\(prefix).stdout")
        let err = folder.appendingPathComponent("\(prefix).stderr")
        _ = FileManager.default.createFile(atPath: out.path, contents: nil)
        _ = FileManager.default.createFile(atPath: err.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: out)
        let stderr = try FileHandle(forWritingTo: err)
        defer {
            try? stdout.close(); try? stderr.close()
            try? FileManager.default.removeItem(at: out); try? FileManager.default.removeItem(at: err)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard !process.isRunning else {
            process.terminate()
            throw E2EFailure("\(executable) did not finish in \(timeout)s")
        }
        return CommandResult(status: process.terminationStatus,
                             output: try String(contentsOf: out, encoding: .utf8),
                             error: try String(contentsOf: err, encoding: .utf8))
    }
}
