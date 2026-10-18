import Testing
@testable import Stampo

@Suite struct ScrollSidewaysSectionTests {
    private func canInspect(axis: ScrollAxis = .vertical, undecided: Bool = true, push: Bool = false,
                            expected: Int? = 90, confirmed: Bool = true, changed: Bool = true,
                            contradicted: Bool = false, mode: ScrollPush.Mode = .none,
                            checking: Bool = false) -> Bool {
        ScrollSidewaysSection.canInspect(axis: axis, verticalUndecided: undecided, isPush: push,
                                         expected: expected, calibrationConfirmed: confirmed,
                                         frameChanged: changed, contradicted: contradicted,
                                         pushMode: mode, checking: checking)
    }

    @Test func entryRequiresEveryGuardBeforeAnySidewaysSearch() {
        #expect(canInspect())
        #expect(!canInspect(axis: .horizontal))
        #expect(!canInspect(undecided: false))
        #expect(!canInspect(push: true))
        #expect(!canInspect(expected: nil))
        #expect(!canInspect(confirmed: false))
        #expect(!canInspect(changed: false))
        #expect(!canInspect(contradicted: true))
        #expect(!canInspect(checking: true))
        for mode: ScrollPush.Mode in [.push, .settle, .section(pushes: 2), .check(pushes: 2)] {
            #expect(!canInspect(mode: mode))
        }
    }

    @Test func entryLaysOnlyAConfirmedQueuedPathAndOtherwiseReplaces() {
        #expect(ScrollSidewaysSection.entry(queueIsEmpty: false, calibrationConfirmed: true,
                                            expected: 90) == .lay(90))
        #expect(ScrollSidewaysSection.entry(queueIsEmpty: true, calibrationConfirmed: true,
                                            expected: 90) == .replace)
        for empty in [false, true] {
            #expect(ScrollSidewaysSection.entry(queueIsEmpty: empty, calibrationConfirmed: false,
                                                expected: 90) == nil)
            #expect(ScrollSidewaysSection.entry(queueIsEmpty: empty, calibrationConfirmed: true,
                                                expected: nil) == nil)
        }
        #expect(!ScrollStepPlacement.gallery.cleanStep)
        #expect(!ScrollStepPlacement.gallery.updatesCalibration)
    }

    @Test func theTwentyFourthReplacementEndsAnUnboundedSection() throws {
        #expect(ScrollSidewaysSection.limit == 24)
        var section = ScrollSidewaysSection()
        var assembler = ImageAssembler(axis: .vertical)
        var previous = cards(0)
        assembler.begin(with: previous)
        for count in 1...24 {
            #expect(!section.isExhausted)
            let current = cards(count * 10)
            #expect(try section.replaceLast(previous: previous, current: current, in: &assembler))
            #expect(section.stages == count)
            previous = current
        }
        #expect(section.isExhausted)
    }

    @Test func replacingADifferentPositionDoesNothing() throws {
        var section = ScrollSidewaysSection()
        let laid = cards(0), queued = cards(0, vertical: 90)
        var assembler = ImageAssembler(axis: .vertical)
        assembler.begin(with: laid)
        #expect(try !section.replaceLast(previous: queued, current: cards(80), in: &assembler))
        #expect(assembler.lastFrame == laid)
        #expect(!section.isActive)
    }

    @Test func theSharedAppendResetsTheLatchForEveryVerticalPlacement() throws {
        // Session lay uses this append for matched, recovered, parallax,
        // calibrated queue and forward-landing paths; no manual reset here.
        for placement: ScrollStepPlacement in [.matched(cleanStep: true), .recovered, .parallax, .gallery] {
            var section = ScrollSidewaysSection()
            var assembler = ImageAssembler(axis: .vertical)
            let previous = cards(0), current = cards(80)
            assembler.begin(with: previous)
            #expect(try section.replaceLast(previous: previous, current: current, in: &assembler))
            #expect(section.isActive)
            try section.append(cards(80, vertical: 90), movement: 90, to: &assembler)
            #expect(!section.isActive)
            #expect(section.stages == 0)
            if !placement.updatesCalibration { #expect(!placement.cleanStep) }
        }
        // The same append is used without a placement by queue laying and
        // landReturn(.further), and must reset the latch there as well.
        for _ in 0..<2 {
            var section = ScrollSidewaysSection()
            var assembler = ImageAssembler(axis: .vertical)
            assembler.begin(with: cards(0))
            section.acceptedStage(previous: cards(0), current: cards(80))
            try section.append(cards(80, vertical: 90), movement: 90, to: &assembler)
            #expect(section.stages == 0)
        }
    }

    @Test func aFailedOrHorizontalAppendDoesNotResetTheLatch() throws {
        var section = ScrollSidewaysSection()
        section.acceptedStage(previous: cards(0), current: cards(80))
        var empty = ImageAssembler(axis: .vertical)
        #expect(throws: (any Error).self) {
            try section.append(cards(80), movement: 90, to: &empty)
        }
        #expect(section.isActive)
        var horizontal = ImageAssembler(axis: .horizontal)
        horizontal.begin(with: cards(0))
        try section.append(cards(80), movement: 80, to: &horizontal)
        #expect(section.isActive)
    }

    @Test func theLatchSurvivesARefusalButRejectsPushesChecksAndUnchangedFrames() throws {
        var section = ScrollSidewaysSection()
        #expect(!section.canContinue(axis: .vertical, verticalUndecided: true, isPush: false,
                                     frameChanged: true, pushMode: .none, checking: false))
        section.acceptedStage(previous: cards(0), current: cards(80))
        #expect(section.canContinue(axis: .vertical, verticalUndecided: true, isPush: false,
                                    frameChanged: true, pushMode: .none, checking: false))
        #expect(!section.canContinue(axis: .vertical, verticalUndecided: false, isPush: false,
                                     frameChanged: true, pushMode: .none, checking: false))
        #expect(!section.canContinue(axis: .vertical, verticalUndecided: true, isPush: true,
                                     frameChanged: true, pushMode: .none, checking: false))
        #expect(!section.canContinue(axis: .vertical, verticalUndecided: true, isPush: false,
                                     frameChanged: false, pushMode: .none, checking: false))
        #expect(!section.canContinue(axis: .vertical, verticalUndecided: true, isPush: false,
                                     frameChanged: true, pushMode: .none, checking: true))
        // Failure to find a stage does not release the mode.
        #expect(section.inspect(previous: cards(80), current: cards(80, vertical: 90),
                                 expected: 90, consistent: 3, required: 1) == nil)
        #expect(section.isActive)
    }

    @Test func rowsContinueOnlyAnEstablishedGalleryWithoutVerticalSupport() throws {
        func video(_ rotation: Int) -> CaptureFrame {
            let w = 120, h = 240
            var pixels = [UInt8](repeating: 255, count: w * h * 4)
            var seed: UInt32 = 0x12345678
            for pixel in 0..<(w * h) {
                var colors = [UInt8]()
                for _ in 0..<3 {
                    seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                    colors.append(UInt8(truncatingIfNeeded: seed))
                }
                for channel in 0..<3 { pixels[pixel * 4 + channel] = colors[(channel + rotation) % 3] }
            }
            return CaptureFrame(width: w, height: h, pixels: pixels)
        }
        let history = video(2), previous = video(0), current = video(1)
        var section = ScrollSidewaysSection()
        #expect(section.inspect(previous: previous, current: current, expected: 90, consistent: 0, required: 1) == nil)
        section.acceptedStage(previous: history, current: previous)
        #expect(section.inspect(previous: previous, current: current, expected: 90, consistent: 0, required: 1) == .standing)
        #expect(section.inspect(previous: previous, current: current, expected: 90, consistent: 1, required: 1) == nil)
        #expect(section.inspect(previous: previous, current: current, expected: nil, consistent: 0, required: 1) == nil)
        #expect(section.inspect(previous: history, current: current, expected: 90, consistent: 0, required: 1) == nil)
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
            let stage = try #require(section.inspect(previous: previous, current: next, expected: 90,
                                                     consistent: 0, required: 1))
            if case .sideways(let match) = stage { #expect(match.offset == 80) }
            else { Issue.record("Expected sideways displacement") }
            #expect(try section.replaceLast(previous: previous, current: next, in: &assembler))
            previous = next
            #expect(assembler.lastFrame == next)
            #expect(assembler.fullLength == before.height)
        }
        let image = try #require(CaptureFrame(image: try assembler.makeImage()))
        #expect(image.pixels == previous.pixels)
        #expect(section.stages == 3)
        let next = cards(240, vertical: 90)
        let match = try FrameMatcher.match(previous: previous, current: next, axis: .vertical, maximumOffset: 450)
        #expect(match.offset == 90)
        try section.append(next, movement: match.offset, to: &assembler)
        #expect(assembler.fullLength == before.height + 90)
        #expect(section.stages == 0)
    }

    @Test func threeQueuedStepsPreserveTheWayInAndOnlyTheLastGalleryStage() throws {
        var assembler = ImageAssembler(axis: .vertical)
        assembler.begin(with: cards(0))
        var waiting = TemporarySteps()
        for y in [90, 180, 270] { waiting.add(cards(0, vertical: y), movement: 90, confirmed: false) }
        let previous = try #require(waiting.steps.last?.frame)
        let entry = cards(80, vertical: 270)
        var section = ScrollSidewaysSection()
        let stage = try #require(section.inspect(previous: previous, current: entry, expected: 90,
                                                 consistent: 0, required: 1))
        if case .sideways = stage {} else { Issue.record("Entry must have a sideways match") }
        #expect(ScrollSidewaysSection.entry(queueIsEmpty: waiting.isEmpty, calibrationConfirmed: true,
                                            expected: 90) == .lay(90))
        for step in waiting.take() { try section.append(step.frame, movement: step.movement, to: &assembler) }
        try section.append(entry, movement: 90, to: &assembler)
        section.acceptedStage(previous: previous, current: entry)
        #expect(waiting.isEmpty)
        #expect(section.stages == 1)
        #expect(assembler.fullLength == 960)
        let last = cards(160, vertical: 270)
        #expect(try section.replaceLast(previous: entry, current: last, in: &assembler))
        #expect(assembler.fullLength == 960)
        #expect(section.stages == 2)
        let image = try #require(CaptureFrame(image: try assembler.makeImage()))
        #expect(image[17, image.height - 50, 0] == last[17, last.height - 50, 0])
        #expect(assembler.lastFrame == last)
    }
}
