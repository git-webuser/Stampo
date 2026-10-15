import CoreGraphics
import Foundation

/// When the page a scrolling capture looks at is still. A step's frame is taken once the page has stopped moving:
/// two looks 140 ms apart that do not differ. A page that shows a heading by fading it in over a second
/// (apple.com, `staggered-start`) is a small part of the frame that changes slowly, and the mean difference of the
/// whole frame does not feel it: the frame was taken at once, with the heading not yet there. So the frame is cut
/// into tiles and each is looked at: the pair is still when no tile has changed.
nonisolated enum ScrollStillness {
    /// The frame is cut into this many tiles across and down.
    static let grid = 8
    /// A tile has not changed when the mean difference of its pixels, per channel out of 255, is under this.
    static let stillBelow = 0.003
    /// How long the capture waits for stillness, and how far apart the two looks are.
    static let limit: TimeInterval = 1.8
    static let interval: Duration = .milliseconds(140)

    /// The mean difference of each tile of the grid (row by row) between two frames of the same size; nil when
    /// the sizes differ. A tile is sampled every fourth pixel across and down (every pixel when it is small), from
    /// its own corner, and the tiles tile the whole frame whatever its size: the edges of a frame that is not a
    /// multiple of the grid are in the last tile of their row or column.
    static func tileDifferences(_ a: CaptureFrame, _ b: CaptureFrame) -> [Double]? {
        let width = a.width, height = a.height
        guard width > 0, height > 0, b.width == width, b.height == height else { return nil }
        var differences = [Double](repeating: 0, count: grid * grid)
        a.pixels.withUnsafeBufferPointer { before in
            b.pixels.withUnsafeBufferPointer { after in
                for row in 0..<grid {
                    let y0 = row * height / grid, y1 = (row + 1) * height / grid
                    let stepY = y1 - y0 >= 32 ? 4 : 1
                    for column in 0..<grid {
                        let x0 = column * width / grid, x1 = (column + 1) * width / grid
                        let stepX = x1 - x0 >= 32 ? 4 : 1
                        var total = 0, samples = 0
                        var y = y0
                        while y < y1 {
                            var x = x0
                            while x < x1 {
                                let i = (y * width + x) * 4
                                total += abs(Int(before[i]) - Int(after[i]))
                                    + abs(Int(before[i + 1]) - Int(after[i + 1]))
                                    + abs(Int(before[i + 2]) - Int(after[i + 2]))
                                samples += 1
                                x += stepX
                            }
                            y += stepY
                        }
                        differences[row * grid + column] = samples > 0 ? Double(total) / 765 / Double(samples) : 0
                    }
                }
            }
        }
        return differences
    }

    /// Whether no tile has changed.
    static func isStill(tileDifferences: [Double]) -> Bool {
        tileDifferences.allSatisfy { $0 < stillBelow }
    }

    /// Whether the two frames are of a page that is still: the same size and no tile changed.
    static func isStill(_ a: CaptureFrame, _ b: CaptureFrame) -> Bool {
        tileDifferences(a, b).map { isStill(tileDifferences: $0) } ?? false
    }
}
