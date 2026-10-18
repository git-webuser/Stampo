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
        #expect(ScrollSidewaysSection().entry(queueIsEmpty: false, calibrationConfirmed: true,
                                            expected: 90) == .lay(90))
        #expect(ScrollSidewaysSection().entry(queueIsEmpty: true, calibrationConfirmed: true,
                                            expected: 90) == .replace)
        for empty in [false, true] {
            #expect(ScrollSidewaysSection().entry(queueIsEmpty: empty, calibrationConfirmed: false,
                                                expected: 90) == nil)
            #expect(ScrollSidewaysSection().entry(queueIsEmpty: empty, calibrationConfirmed: true,
                                                expected: nil) == nil)
        }
        #expect(!ScrollStepPlacement.gallery.cleanStep)
        #expect(!ScrollStepPlacement.gallery.updatesCalibration)
    }

    @Test func filteredSearchRequiresUnresolvedMotionOrAnEstablishedGallery() {
        var section = ScrollSidewaysSection()
        #expect(!section.needsFilteredSearch(consistent: 1, required: 1))
        #expect(!section.needsFilteredSearch(consistent: 3, required: 1))
        #expect(section.needsFilteredSearch(consistent: 0, required: 1))
        #expect(section.needsFilteredSearch(consistent: 1, required: 2))
        section.acceptedStage(previous: cards(0), current: cards(80))
        #expect(section.needsFilteredSearch(consistent: 1, required: 1))
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
        let history = video(2), previous = video(0), current = video(1)
        var section = ScrollSidewaysSection()
        #expect(section.inspect(previous: previous, current: current, expected: 90, consistent: 0, required: 1) == nil)
        section.acceptedStage(previous: history, current: previous)
        #expect(section.inspect(previous: previous, current: current, expected: 90, consistent: 0, required: 1) == .standing)
        #expect(section.inspect(previous: previous, current: current, expected: 90, consistent: 1, required: 1) == nil)
        #expect(section.inspect(previous: previous, current: current, expected: nil, consistent: 0, required: 1) == nil)
        #expect(section.inspect(previous: history, current: current, expected: 90, consistent: 0, required: 1) == nil)
    }

    private func video(_ rotation: Int) -> CaptureFrame {
        let w = 120, h = 240
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        var seed: UInt32 = 0x12345678
        let order = rotation == 3 ? [0, 2, 1] : (0..<3).map { ($0 + rotation) % 3 }
        for pixel in 0..<(w * h) {
            var colors = [UInt8]()
            for _ in 0..<3 {
                seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                colors.append(UInt8(truncatingIfNeeded: seed))
            }
            for channel in 0..<3 { pixels[pixel * 4 + channel] = colors[order[channel]] }
        }
        return CaptureFrame(width: w, height: h, pixels: pixels)
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
        #expect(section.entry(queueIsEmpty: waiting.isEmpty, calibrationConfirmed: true,
                                            expected: 90) == .lay(90))
        for step in waiting.take() { try section.append(step.frame, movement: step.movement, to: &assembler) }
        #expect(try section.replaceLast(previous: previous, current: entry, in: &assembler))
        #expect(waiting.isEmpty)
        #expect(section.stages == 1)
        #expect(assembler.fullLength == 870)
        let last = cards(160, vertical: 270)
        #expect(try section.replaceLast(previous: entry, current: last, in: &assembler))
        #expect(assembler.fullLength == 870)
        #expect(section.stages == 2)
        let image = try #require(CaptureFrame(image: try assembler.makeImage()))
        #expect(image[17, image.height - 50, 0] == last[17, last.height - 50, 0])
        #expect(assembler.lastFrame == last)
    }

    @Test func queuedStagesAreDroppedWhenTheGalleryFindsItsNextStage() throws {
        var assembler = ImageAssembler(axis: .vertical)
        let first = cards(0), entry = cards(80)
        assembler.begin(with: first)
        var section = ScrollSidewaysSection()
        #expect(try section.replaceLast(previous: first, current: entry, in: &assembler))
        var waiting = TemporarySteps()
        let a = cards(160), queued = cards(240)
        // A refusal waits without releasing the already established gallery.
        waiting.add(a, movement: 90, confirmed: false)
        waiting.add(queued, movement: 90, confirmed: false)
        #expect(section.isActive)
        let next = cards(320)
        #expect(section.inspect(previous: queued, current: next, expected: 90, consistent: 0, required: 1) != nil)
        #expect(section.entry(queueIsEmpty: waiting.isEmpty, calibrationConfirmed: true,
                                            expected: 90) == .replace)
        #expect(section.entry(queueIsEmpty: true, calibrationConfirmed: false, expected: nil) == .replace)
        #expect(section.entry(queueIsEmpty: false, calibrationConfirmed: false, expected: nil) == .replace)
        #expect(try section.replaceQueuedStage(previous: queued, current: next, in: &assembler,
                                               queue: &waiting, consistent: 0, required: 1) == 2)
        #expect(waiting.isEmpty)
        #expect(section.stages == 2)
        #expect(assembler.fullLength == first.height)
        let last = cards(400)
        #expect(try section.replaceLast(previous: next, current: last, in: &assembler))
        #expect(section.stages == 3)
        #expect(assembler.fullLength == first.height)
        #expect(assembler.lastFrame == last)
    }

    @Test func confirmedDownwardMotionKeepsTheQueueAndReleasesTheGallery() throws {
        let first = cards(0), entry = cards(80), a = cards(160), b = cards(240)
        var assembler = ImageAssembler(axis: .vertical)
        assembler.begin(with: first)
        var section = ScrollSidewaysSection(), waiting = TemporarySteps()
        #expect(try section.replaceLast(previous: first, current: entry, in: &assembler))
        waiting.add(a, movement: 90, confirmed: false)
        waiting.add(b, movement: 90, confirmed: false)
        #expect(try section.replaceQueuedStage(previous: b, current: cards(320, vertical: 90), in: &assembler,
                                               queue: &waiting, consistent: 1, required: 1) == nil)
        #expect(waiting.count == 2)
        #expect(waiting.steps.last?.frame == b)
        #expect(assembler.lastFrame == entry)
        #expect(assembler.fullLength == first.height)
        #expect(!section.isActive)
    }

    @Test func queuedRowHistoryCanRecognizeAStandingStageWithoutAHorizontalMatch() throws {
        let laid = video(3), a = video(2), b = video(0), c = video(1)
        var assembler = ImageAssembler(axis: .vertical)
        assembler.begin(with: laid)
        var section = ScrollSidewaysSection(), waiting = TemporarySteps()
        section.acceptedStage(previous: a, current: laid)
        waiting.add(a, movement: 90, confirmed: false)
        waiting.add(b, movement: 90, confirmed: false)
        #expect(section.inspect(previous: b, current: c, expected: 90, consistent: 0, required: 1) == nil)
        #expect(section.inspect(previous: b, current: c, expected: 90, consistent: 0, required: 1,
                                queued: [a, b]) == .standing)
        #expect(try section.replaceQueuedStage(previous: b, current: c, in: &assembler,
                                               queue: &waiting, consistent: 0, required: 1) == 2)
        #expect(waiting.isEmpty)
        #expect(section.stages == 2)
        #expect(assembler.fullLength == laid.height)
        #expect(assembler.lastFrame == c)
    }

    @Test func standingQueuedRowsCannotDiscardAnExitFromTheLaidGalleryPosition() throws {
        func shifted(_ frame: CaptureFrame) -> CaptureFrame {
            let split = 90 * frame.width * 4
            return CaptureFrame(width: frame.width, height: frame.height,
                                pixels: Array(frame.pixels[split...]) + Array(frame.pixels[..<split]))
        }
        let laid = video(3), a = shifted(video(2)), b = shifted(video(0)), c = shifted(video(1))
        var assembler = ImageAssembler(axis: .vertical)
        assembler.begin(with: laid)
        var section = ScrollSidewaysSection(), waiting = TemporarySteps()
        section.acceptedStage(previous: video(2), current: laid)
        waiting.add(a, movement: 90, confirmed: false)
        waiting.add(b, movement: 90, confirmed: false)
        #expect(try #require(ScrollRowProfile.inspect(history: a, previous: b, current: c, expected: 90)).stands)
        #expect(section.inspect(previous: b, current: c, expected: 90, consistent: 0, required: 1,
                                queued: [a, b]) == nil)
        #expect(assembler.lastFrame == laid)
        #expect(assembler.fullLength == laid.height)
        #expect(waiting.count == 2)
        #expect(section.stages == 1)
    }

    /// Gallery cards whose rows each carry an energy of their own, as the rows
    /// of a real page do, wherever the cards are horizontally: the row profile
    /// can then tell a gallery that moved sideways from one that went down.
    private func rowCards(_ offset: Int, vertical: Int = 0) -> CaptureFrame {
        let width = 480, height = 600
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let py = y + vertical
            let amplitude = 20 + (py * 37) % 120
            for x in 0..<width {
                let px = x + offset
                let texture = (px * 73 + py * 31 + (px / 7) * (py / 11) * 17) % 220 + 15
                let value = UInt8(30 + amplitude * texture / 255)
                for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = value }
            }
        }
        return CaptureFrame(width: width, height: height, pixels: pixels)
    }

    /// What the session does with a frame that waits behind a laid gallery:
    /// the stage is judged off the main thread with the queue's frames, and
    /// only a stage found there replaces the laid frame and drops the queue.
    private func stageThroughQueue(_ section: inout ScrollSidewaysSection, current: CaptureFrame,
                                   in assembler: inout ImageAssembler, queue: inout TemporarySteps,
                                   consistent: Int = 0, required: Int = 1) throws -> Int? {
        let queued = queue.steps.map(\.frame)
        let previous = try #require(queued.last)
        guard section.inspect(previous: previous, current: current, expected: 90, consistent: consistent,
                              required: required, queued: queued) != nil
        else { return nil }
        return try section.replaceQueuedStage(previous: previous, current: current, in: &assembler,
                                              queue: &queue, consistent: consistent, required: required)
    }

    /// A gallery laid at `rowCards(40)` with frames at `offsets` waiting behind it.
    private func laidGallery(waiting offsets: [Int]) throws -> (ImageAssembler, ScrollSidewaysSection, TemporarySteps) {
        let first = rowCards(0), laid = rowCards(40)
        var assembler = ImageAssembler(axis: .vertical)
        assembler.begin(with: first)
        var section = ScrollSidewaysSection(), waiting = TemporarySteps()
        #expect(try section.replaceLast(previous: first, current: laid, in: &assembler))
        for offset in offsets { waiting.add(rowCards(offset), movement: 90, confirmed: false) }
        return (assembler, section, waiting)
    }

    @Test func aSidewaysMatchAtTheQueueEndCannotDiscardADownwardExit() throws {
        // The gallery is laid; the page then goes down in two unconfirmed steps
        // and a section below it moves sideways, matching the queue's end.
        let a = rowCards(40, vertical: 90), b = rowCards(40, vertical: 180)
        let current = rowCards(120, vertical: 180)
        #expect(try FrameMatcher.match(previous: b, current: current, axis: .horizontal,
                                       maximumOffset: b.width / 2).offset == 80)
        var (assembler, section, waiting) = try laidGallery(waiting: [])
        let laid = try #require(assembler.lastFrame), length = assembler.fullLength
        waiting.add(a, movement: 90, confirmed: false)
        waiting.add(b, movement: 90, confirmed: false)
        #expect(try stageThroughQueue(&section, current: current, in: &assembler, queue: &waiting) == nil)
        #expect(waiting.count == 2)
        #expect(waiting.steps.last?.frame == b)
        #expect(assembler.lastFrame == laid)
        #expect(assembler.fullLength == length)
        #expect(section.stages == 1)
        #expect(section.isActive)
        // The same frame beside a queue that is not there is an ordinary stage.
        #expect(section.inspect(previous: b, current: current, expected: 90, consistent: 0, required: 1) != nil)
    }

    @Test func everyQueuedFrameMustStandWhereTheLaidStageStood() throws {
        // The first link catches a queue that left the gallery's height and
        // then moved sideways, whose last pair alone looks like a gallery.
        var (assembler, section, waiting) = try laidGallery(waiting: [])
        waiting.add(rowCards(80, vertical: 90), movement: 90, confirmed: false)
        waiting.add(rowCards(120, vertical: 90), movement: 90, confirmed: false)
        #expect(try stageThroughQueue(&section, current: rowCards(160, vertical: 90),
                                      in: &assembler, queue: &waiting) == nil)
        #expect(waiting.count == 2)
        // The last link catches a queue that began at the gallery's height.
        var (second, other, tail) = try laidGallery(waiting: [80])
        tail.add(rowCards(120, vertical: 90), movement: 90, confirmed: false)
        #expect(try stageThroughQueue(&other, current: rowCards(160, vertical: 90), in: &second, queue: &tail) == nil)
        #expect(tail.count == 2)
        #expect(other.stages == 1)
    }

    @Test func aSidewaysMatchThatStaysAtTheLaidStageStillDropsTheQueue() throws {
        // Brave 212758: a missed stage waits, and the next stage matches it.
        for waitingOffsets in [[80], [80, 120]] {
            var (assembler, section, waiting) = try laidGallery(waiting: waitingOffsets)
            let length = assembler.fullLength, current = rowCards(waitingOffsets.last! + 40)
            #expect(try stageThroughQueue(&section, current: current, in: &assembler,
                                          queue: &waiting) == waitingOffsets.count)
            #expect(waiting.isEmpty)
            #expect(section.stages == 2)
            #expect(assembler.fullLength == length)
            #expect(assembler.lastFrame == current)
        }
    }

    @Test func aGalleryCannotDropMoreThanTwoQueuedFrames() throws {
        #expect(ScrollSidewaysSection.queuedStageLimit == 2)
        var (assembler, section, waiting) = try laidGallery(waiting: [80, 120, 160])
        let length = assembler.fullLength, laid = rowCards(40)
        let previous = rowCards(160), current = rowCards(200)
        #expect(section.inspect(previous: previous, current: current, expected: 90, consistent: 0, required: 1,
                                queued: waiting.steps.map(\.frame)) == nil)
        #expect(try section.replaceQueuedStage(previous: previous, current: current, in: &assembler,
                                               queue: &waiting, consistent: 0, required: 1) == nil)
        #expect(waiting.count == 3)
        #expect(assembler.lastFrame == laid)
        #expect(assembler.fullLength == length)
        #expect(section.stages == 1)
        // Without the limit the same pair is a stage, so the limit is what refused it.
        let twoLeft = waiting.steps.suffix(2).map(\.frame)
        #expect(section.inspect(previous: previous, current: current, expected: 90, consistent: 0, required: 1,
                                queued: twoLeft) != nil)
    }

    @Test func queueingFramesNeverReleasesTheLatchButSupportedDownMotionDoes() throws {
        var section = ScrollSidewaysSection(), waiting = TemporarySteps()
        section.acceptedStage(previous: cards(0), current: cards(80))
        for offset in [160, 240] {
            // A frame that waits has no vertical support behind it.
            waiting.add(cards(offset), movement: 90, confirmed: false)
            let none = section.releaseForVerticalSupport(consistent: 0, required: 1)
            let short = section.releaseForVerticalSupport(consistent: 1, required: 2)
            #expect(!none && !short)
            #expect(section.isActive)
        }
        let released = section.releaseForVerticalSupport(consistent: 1, required: 1)
        #expect(released)
        #expect(!section.isActive)
        #expect(section.stages == 0)
        let again = section.releaseForVerticalSupport(consistent: 3, required: 1)
        #expect(!again)
        #expect(waiting.count == 2)
    }

    @Test func inspectRejectsQueuedVerticalSupportBeforeSearchingSideways() throws {
        let previous = rowCards(80), current = rowCards(120)
        var section = ScrollSidewaysSection()
        section.acceptedStage(previous: rowCards(0), current: rowCards(40))
        #expect(section.inspect(previous: previous, current: current, expected: 90, consistent: 1, required: 1,
                                queued: [previous]) == nil)
        #expect(section.inspect(previous: previous, current: current, expected: 90, consistent: 1, required: 1) != nil)
        #expect(section.inspect(previous: previous, current: current, expected: 90, consistent: 0, required: 1,
                                queued: [previous]) != nil)
    }

    private func filteredCards(_ offset: Int) -> CaptureFrame {
        let width = 240, height = 160
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let px = x + offset
                let detail = (px * 73 + y * 31 + (px / 7) * (y / 11) * 17) % 40
                let value = UInt8(20 + x / 2 + detail)
                for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = value }
            }
        }
        return CaptureFrame(width: width, height: height, pixels: pixels)
    }

    @Test func inspectSkipsAnHPOnlyEntryWhenRawTilesSupportVerticalMotion() throws {
        let previous = filteredCards(0), current = filteredCards(48)
        #expect(throws: (any Error).self) {
            try FrameMatcher.match(previous: previous, current: current, axis: .horizontal,
                                   maximumOffset: previous.width / 2)
        }
        let filtered = try FrameMatcher.match(previous: ScrollBackgroundFilter.highPass(previous, radius: 4),
                                              current: ScrollBackgroundFilter.highPass(current, radius: 4),
                                              axis: .horizontal, maximumOffset: previous.width / 2)
        #expect(filtered.offset == 48)
        var section = ScrollSidewaysSection()
        for supporting in [1, 3] {
            #expect(section.inspect(previous: previous, current: current, expected: 90,
                                    consistent: supporting, required: 1) == nil)
        }
        let entry = try #require(section.inspect(previous: previous, current: current, expected: 90,
                                                consistent: 0, required: 1))
        if case .sideways(let match) = entry { #expect(match.offset == 48) }
        else { Issue.record("Expected the filtered sideways displacement") }
        section.acceptedStage(previous: previous, current: current)
        #expect(section.inspect(previous: previous, current: current, expected: 90,
                                consistent: 1, required: 1) != nil)
    }
}
