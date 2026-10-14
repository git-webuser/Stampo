import CoreGraphics
@testable import Stampo

/// Synthetic scrolls for the seam tests: a page of noise, with an element that
/// is part-way through appearing in the earlier frames and finished in the
/// last, and, optionally, a panel fixed to the viewport.
///
/// Everything is in rows along the scroll, whichever the axis: for a
/// horizontal scroll a row is a column of the frame. A frame is `length` rows
/// of `across` pixels and each is `movement` rows further on than the last.
/// No `Testing` here, so that the scenes can be run on their own.
nonisolated enum SeamScenes {
    static let across = 60
    static let length = 200
    static let movement = 60

    /// How the element looks in a frame.
    enum State {
        /// Not there: the page, as it is everywhere else.
        case absent
        /// Arriving: a pale element, five rows below where it will be.
        case pale
        /// Finished: dark, in place.
        case finished
        /// Nothing but white where the element will be — whole rows.
        case blank
    }

    struct Scene {
        var axis: ScrollAxis = .vertical
        /// The page rows the finished element covers.
        var element: Range<Int> = 120..<150
        /// The columns across it covers.
        var columns: Range<Int> = 10..<50
        /// The rows of every frame (not of the page) that a panel fixed to the
        /// viewport covers.
        var panel: Range<Int>?
        /// The element in each frame, first to last.
        var states: [State] = [.pale, .finished]
        var scale: CGFloat = 1
        /// Drop the image to half size before laying the frame of this index.
        var shrinkBefore: Int?
    }

    struct Outcome {
        /// The seam of each frame after the first, as the assembler reports it.
        var seams: [ScrollSeam.Choice]
        var assembler: ImageAssembler
        var image: CGImage
    }

    // MARK: Pixels

    private static func noise(_ a: Int, _ b: Int) -> UInt64 {
        var hash = (UInt64(bitPattern: Int64(a)) &* 0x9E37_79B9_7F4A_7C15)
            ^ (UInt64(bitPattern: Int64(b)) &* 0xD1B5_4A32_D192_ED03)
        hash ^= hash >> 30
        hash &*= 0xBF58_476D_1CE4_E5B9
        hash ^= hash >> 27
        hash &*= 0x94D0_49BB_1331_11EB
        hash ^= hash >> 31
        return hash
    }

    /// The page: noise between 80 and 249, so that nothing else in a scene is
    /// within 8 of the element's 10 or 40, or of the panel's 0 to 70.
    static func page(_ row: Int, _ column: Int) -> UInt8 {
        80 + UInt8(truncatingIfNeeded: noise(row, column) % 170)
    }

    static func panelPixel(_ row: Int, _ column: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: noise(row &+ 7_919, column &+ 104_729) % 71)
    }

    /// The page as the element's `state` has it, at page row `row`.
    static func pixel(_ row: Int, _ column: Int, _ scene: Scene, _ state: State) -> UInt8 {
        switch state {
        case .absent:
            break
        case .finished:
            if scene.element.contains(row), scene.columns.contains(column) { return 10 }
        case .pale:
            let shifted = (scene.element.lowerBound + 5)..<(scene.element.upperBound + 5)
            if shifted.contains(row), scene.columns.contains(column) { return 40 }
        case .blank:
            if scene.element.contains(row) { return 255 }
        }
        return page(row, column)
    }

    static func frame(_ index: Int, of scene: Scene) -> CaptureFrame {
        let vertical = scene.axis == .vertical
        let width = vertical ? across : length, height = vertical ? length : across
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<length {
            for column in 0..<across {
                let value = scene.panel?.contains(row) == true
                    ? panelPixel(row, column)
                    : pixel(index * movement + row, column, scene, scene.states[index])
                let i = ((vertical ? row * width + column : column * width + row)) * 4
                bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value
            }
        }
        return CaptureFrame(width: width, height: height, pixels: bytes)
    }

    // MARK: Running

    static func run(_ scene: Scene) throws -> Outcome {
        var assembler = ImageAssembler(axis: scene.axis, maxLength: 10_000, scale: scene.scale)
        assembler.begin(with: frame(0, of: scene))
        var seams: [ScrollSeam.Choice] = []
        for index in 1..<scene.states.count {
            if scene.shrinkBefore == index { assembler.shrinkToHalf() }
            try assembler.append(frame(index, of: scene), movement: movement)
            if let seam = assembler.lastSeam { seams.append(seam) }
        }
        return Outcome(seams: seams, assembler: assembler, image: try assembler.makeImage(maxPixels: 1_000_000))
    }

    // MARK: Reading the image back

    /// The pixel of the assembled image at page row `row`, column `column`.
    static func imagePixel(_ image: CaptureFrame, _ scene: Scene, row: Int, column: Int) -> UInt8 {
        scene.axis == .vertical ? image[column, row, 0] : image[row, column, 0]
    }

    /// The first page row, outside `ignoring`, where the assembled image is not
    /// the page with the element as `state` has it — nil when there is none.
    static func firstMismatch(of image: CGImage, in scene: Scene, as state: State,
                              ignoring: Range<Int> = 0..<0) -> String? {
        guard let frame = CaptureFrame(image: image) else { return "no image" }
        let rows = scene.axis == .vertical ? frame.height : frame.width
        let expectedRows = (scene.states.count - 1) * movement + length
        if rows != expectedRows { return "\(rows) rows, expected \(expectedRows)" }
        for row in 0..<rows where !ignoring.contains(row) {
            for column in 0..<across {
                let got = imagePixel(frame, scene, row: row, column: column)
                let want = pixel(row, column, scene, state)
                if got != want { return "row \(row) column \(column): \(got), expected \(want)" }
            }
        }
        return nil
    }

    /// Whether every pixel of the image over the page rows `rows` is the plain
    /// page — no element, no panel.
    static func isPlainPage(_ image: CGImage, in scene: Scene, rows: Range<Int>) -> Bool {
        guard let frame = CaptureFrame(image: image) else { return false }
        return rows.allSatisfy { row in
            (0..<across).allSatisfy { imagePixel(frame, scene, row: row, column: $0) == page(row, $0) }
        }
    }
}
