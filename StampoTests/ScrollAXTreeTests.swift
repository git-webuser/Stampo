import CoreGraphics
import Testing
@testable import Stampo

@Suite struct ScrollAXTreeTests {
    @Test func aLineContainsOnlyDepthRoleGeometryAndScrollbarFlags() {
        let frame = CGRect(x: -20, y: 50, width: 800, height: 600)
        #expect(ScrollAXTree.line(depth: 2, role: "AXScrollArea", frame: frame,
                                 horizontal: true, vertical: true) == "2 AXScrollArea@-20,50 800x600+hbar+vbar")
        #expect(ScrollAXTree.line(depth: 0, role: "AXWindow", frame: frame,
                                 horizontal: false, vertical: false) == "0 AXWindow@-20,50 800x600")
        #expect(ScrollAXTree.line(depth: 1, role: "AXGroup", frame: nil,
                                 horizontal: false, vertical: true) == "1 AXGroup@<frame-unavailable>+vbar")
    }

    @Test func theWalkIsBreadthFirstAndIncludesDepthEightButDoesNotExpandIt() {
        let lines = ScrollAXTree.breadthFirst(from: 0,
            describe: { "\($1):\($0)" }, children: { node, _ in node < 2 ? [node * 2 + 1, node * 2 + 2] : [] })
        #expect(lines == ["0:0", "1:1", "1:2", "2:3", "2:4"])
        var expanded: [Int] = []
        let chain = ScrollAXTree.breadthFirst(from: 0, describe: { "\($1):\($0)" }, children: { node, _ in
            expanded.append(node)
            return [node + 1]
        })
        #expect(chain == (0...8).map { "\($0):\($0)" })
        #expect(expanded == Array(0..<8))
    }

    @Test func theQueueAndTheOutputAreLimitedToThreeHundredElements() {
        var requested: [Int] = []
        let lines = ScrollAXTree.breadthFirst(from: 0, describe: { node, _ in "\(node)" }, children: { _, count in
            requested.append(count)
            return Array(1...1000)
        })
        #expect(lines == (0..<300).map(String.init))
        #expect(requested == [299])
    }

    @Test func anExpiredBudgetStopsBeforeAnotherElementOrItsChildrenAreRead() {
        var active = true
        var expanded = false
        let lines = ScrollAXTree.breadthFirst(from: 0, shouldContinue: { active }, describe: { _, _ in
            active = false
            return "late"
        }, children: { _, _ in expanded = true; return [1] })
        #expect(lines.isEmpty)
        #expect(!expanded)
        let stopped = ScrollAXTree.breadthFirst(from: 0, shouldContinue: { false },
            describe: { _, _ in Issue.record("Read after deadline"); return "late" }, children: { _, _ in [] })
        #expect(stopped.isEmpty)
    }
}
