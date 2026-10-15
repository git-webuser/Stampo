import Foundation
import CoreGraphics

/// A bounded record of roles and geometry helps diagnose missing scroll areas
/// without reading titles or values from the application's content.
nonisolated enum ScrollAXTree {
    static let maximumDepth = 8
    static let maximumCount = 300

    enum StopReason: String {
        case time, count, end
    }

    static func stopReason(count: Int, timedOut: Bool) -> StopReason {
        if timedOut { return .time }
        return count >= maximumCount ? .count : .end
    }

    static func header(axis: ScrollAxis, count: Int, stoppedBy reason: StopReason) -> String {
        "ax tree (area not found, \(axis.rawValue)): \(count) elements · stopped by \(reason.rawValue)"
    }

    static func line(depth: Int, role: String, frame: CGRect?, horizontal: Bool, vertical: Bool) -> String {
        let geometry = frame.map {
            String(format: "%.0f,%.0f %.0fx%.0f", $0.minX, $0.minY, $0.width, $0.height)
        } ?? "<frame-unavailable>"
        return "\(depth) \(role)@\(geometry)\(horizontal ? "+hbar" : "")\(vertical ? "+vbar" : "")"
    }

    static func breadthFirst<Element>(from root: Element, maximumDepth: Int = maximumDepth,
                                      maximumCount: Int = maximumCount,
                                      shouldContinue: () -> Bool = { true },
                                      describe: (Element, Int) -> String?,
                                      children: (Element, Int) -> [Element]) -> [String] {
        guard maximumDepth >= 0, maximumCount > 0 else { return [] }
        var queue = [(root, 0)]
        var index = 0
        var lines: [String] = []
        while index < queue.count, shouldContinue() {
            let (element, depth) = queue[index]
            index += 1
            guard let line = describe(element, depth), shouldContinue() else { break }
            lines.append(line)
            let remaining = maximumCount - queue.count
            if depth < maximumDepth, remaining > 0, shouldContinue() {
                queue.append(contentsOf: children(element, remaining).prefix(remaining).map { ($0, depth + 1) })
            }
        }
        return lines
    }
}
