import Testing
@testable import Stampo

@Suite struct ScrollSidewaysSectionTests {
    private func stage(axis: ScrollAxis = .vertical, undecided: Bool = true, changed: Bool = true,
                       mode: ScrollPush.Mode = .none, checking: Bool = false, empty: Bool = true,
                       matched: Bool = true) -> Bool {
        ScrollSidewaysSection.isStage(axis: axis, verticalUndecided: undecided, frameChanged: changed,
                                     pushMode: mode, checking: checking, queueIsEmpty: empty,
                                     sidewaysMatched: matched)
    }

    @Test func aRefusedVerticalStepWithASidewaysMatchIsAStage() {
        #expect(stage())
        #expect(!stage(matched: false))
        #expect(!stage(undecided: false))
        #expect(!stage(axis: .horizontal))
        #expect(!stage(changed: false))
    }

    @Test func aWaitingFrameCannotReplaceTheLastLaidFrame() {
        #expect(!stage(empty: false))
    }

    @Test func pushesAndTheirSectionsKeepTheirOwnRules() {
        for mode: ScrollPush.Mode in [.push, .settle, .section(pushes: 2), .check(pushes: 2)] {
            #expect(!stage(mode: mode))
        }
        #expect(!stage(checking: true))
    }

    @Test func theTwentyFourthReplacementEndsAnUnboundedSection() {
        var section = ScrollSidewaysSection()
        for count in 1...ScrollSidewaysSection.limit {
            #expect(!section.isExhausted)
            section.replacedFrame()
            #expect(section.stages == count)
        }
        #expect(section.isExhausted)
    }

    @Test func onlyALaidVerticalStepStartsANewCount() {
        var section = ScrollSidewaysSection()
        for _ in 0..<ScrollSidewaysSection.limit { section.replacedFrame() }
        section.laidVerticalStep()
        #expect(section.stages == 0)
        #expect(!section.isExhausted)
        section.replacedFrame()
        #expect(section.stages == 1)
    }

    private func cards(_ offset: Int, vertical: Int = 0) -> CaptureFrame {
        let width = 480, height = 600
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let px = x + offset, py = y + vertical
                let value = UInt8((px * 73 + py * 31 + (px / 7) * (py / 11) * 17) % 220 + 15)
                for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = value }
            }
        }
        return CaptureFrame(width: width, height: height, pixels: pixels)
    }

    @Test func sidewaysCardsReplaceOneFrameWithoutGrowingTheImage() throws {
        let before = cards(0)
        var assembler = ImageAssembler(axis: .vertical)
        assembler.begin(with: before)
        var section = ScrollSidewaysSection()
        var previous = before
        for offset in [80, 160, 240] {
            let next = cards(offset)
            #expect(throws: (any Error).self) {
                try FrameMatcher.match(previous: previous, current: next, axis: .vertical, maximumOffset: 450)
            }
            let match = try FrameMatcher.match(previous: previous, current: next, axis: .horizontal,
                                              maximumOffset: before.width * 3 / 4 + 32)
            #expect(match.offset == 80)
            #expect(stage(matched: true))
            try assembler.replaceLast(with: next)
            section.replacedFrame()
            previous = next
            #expect(assembler.lastFrame == next)
            #expect(assembler.fullLength == before.height)
            #expect(assembler.totalLength == before.height)
        }
        let image = try #require(CaptureFrame(image: try assembler.makeImage()))
        #expect(image.pixels == previous.pixels)
        #expect(section.stages == 3)

        let next = cards(240, vertical: 90)
        let match = try FrameMatcher.match(previous: previous, current: next, axis: .vertical, maximumOffset: 450)
        #expect(match.offset == 90)
        #expect(!stage(undecided: false))
        try assembler.append(next, movement: match.offset)
        section.laidVerticalStep()
        #expect(assembler.fullLength == before.height + 90)
        #expect(section.stages == 0)
    }
}
