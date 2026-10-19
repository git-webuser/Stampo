import Testing
@testable import Stampo

@Suite struct ScrollUnreadableStretchTests {
    private func situation(_ trigger: ScrollUnreadableStretch.Trigger = .queueFull(queued: 8),
                           vertical: Bool = true, gallery: Bool = false, pushing: Bool = false,
                           changes: Bool = true, repeats: Bool = false) -> ScrollUnreadableStretch.Situation {
        .init(trigger: trigger, isVertical: vertical, galleryActive: gallery, pushing: pushing,
              framesChange: changes, isRepeat: repeats)
    }

    // MARK: When

    @Test func aFullQueueOfFramesThatChangeIsAStretch() {
        let stretch = ScrollUnreadableStretch()
        #expect(stretch.decide(situation()) == .series)
        // A queue that is not full is the ordinary way: more steps may still place it.
        for queued in [0, 1, TemporarySteps.limit - 1] {
            #expect(stretch.decide(situation(.queueFull(queued: queued))) == .save)
        }
        #expect(stretch.decide(situation(.queueFull(queued: TemporarySteps.limit + 1))) == .series)
    }

    @Test func aPageThatStandsWithStepsWaitingIsAStretchOnTheStepThatWouldEndTheCapture() {
        let stretch = ScrollUnreadableStretch()
        #expect(ScrollUnreadableStretch.Trigger.endingCount == 3)
        #expect(stretch.decide(situation(.standing(count: 3, queued: 3))) == .series)
        #expect(stretch.decide(situation(.standing(count: 3, queued: 1))) == .series)
        // Before it the page may still go on, with the steps waiting as they were.
        #expect(stretch.decide(situation(.standing(count: 2, queued: 3))) == .save)
        #expect(stretch.decide(situation(.standing(count: 1, queued: 3))) == .save)
        // Nothing waits: that is the end of the content.
        #expect(stretch.decide(situation(.standing(count: 3, queued: 0))) == .save)
    }

    @Test func aFrameIsAnotherScreenFromFourHundredthsOfDifference() {
        #expect(ScrollUnreadableStretch.differentFrom == 0.04)
        // claude.com 2026-10-14-214945: the last frame of the page, 0.0062 from the one before;
        // 2026-10-10-003948: 0.0188.
        for difference in [0.0, 0.0002, 0.0062, 0.0188, 0.0399] {
            #expect(!ScrollUnreadableStretch.isAnotherScreen(difference: difference))
        }
        // The smallest stretch of the recordings, 2026-10-11-185309, differs by 0.0757.
        for difference in [0.04, 0.0757, 0.3] {
            #expect(ScrollUnreadableStretch.isAnotherScreen(difference: difference))
        }
    }

    @Test func everyOtherConditionKeepsTheCaptureEndingAsItWould() {
        let stretch = ScrollUnreadableStretch()
        for trigger: ScrollUnreadableStretch.Trigger in [.queueFull(queued: 8), .standing(count: 3, queued: 3)] {
            #expect(stretch.decide(situation(trigger, vertical: false)) == .save)
            #expect(stretch.decide(situation(trigger, pushing: true)) == .save)
            // The frames are the same as the last one laid: the page stands in them (003948, 185058, 185700).
            #expect(stretch.decide(situation(trigger, changes: false)) == .save)
            // A page that is going round shows what the capture has laid.
            #expect(stretch.decide(situation(trigger, repeats: true)) == .save)
        }
    }

    @Test func aLatchedGalleryBlocksOnlyAsLongAsItCouldStillTakeTheQueueAsStages() {
        let stretch = ScrollUnreadableStretch()
        #expect(ScrollSidewaysSection.queuedStageLimit == 2)
        // Up to the frames a stage may drop, the gallery is looked at first.
        for queued in 1...ScrollSidewaysSection.queuedStageLimit {
            let standing = situation(.standing(count: 3, queued: queued), gallery: true)
            #expect(stretch.decide(standing) == .save)
            #expect(stretch.refusal(standing) == .galleryLatched)
        }
        // Past it no stage can be taken, and a latch that nothing releases (2026-10-19-131538 and
        // 2026-10-19-131122: stages to step 26, then eight steps in the queue) is no reason to end.
        let longer = ScrollSidewaysSection.queuedStageLimit + 1
        #expect(stretch.decide(situation(.standing(count: 3, queued: longer), gallery: true)) == .series)
        #expect(stretch.decide(situation(.queueFull(queued: TemporarySteps.limit), gallery: true)) == .series)
        // Without the latch the queue's length does not matter beyond the trigger's own.
        #expect(stretch.decide(situation(.standing(count: 3, queued: 1), gallery: false)) == .series)
    }

    @Test func everyRefusalSaysWhy() {
        var stretch = ScrollUnreadableStretch()
        let full = ScrollUnreadableStretch.Trigger.queueFull(queued: 8)
        #expect(stretch.refusal(situation(full)) == nil)
        #expect(stretch.refusal(situation(full, vertical: false)) == .notVertical)
        #expect(stretch.refusal(situation(.standing(count: 3, queued: 2), gallery: true)) == .galleryLatched)
        #expect(stretch.refusal(situation(full, pushing: true)) == .pushing)
        #expect(stretch.refusal(situation(full, changes: false)) == .framesDoNotChange)
        #expect(stretch.refusal(situation(full, repeats: true)) == .repeatsPage)
        #expect(stretch.refusal(situation(.queueFull(queued: 7))) == .queueNotFull)
        #expect(stretch.refusal(situation(.standing(count: 2, queued: 3))) == .notStandingLongEnough)
        stretch.begin()
        #expect(stretch.refusal(situation(full)) == .underway)
        // The reasons are the words of the log.
        let notes = [ScrollUnreadableStretch.Refusal.notVertical, .galleryLatched, .pushing, .underway,
                     .framesDoNotChange, .repeatsPage, .queueNotFull, .notStandingLongEnough].map(\.note)
        #expect(Set(notes).count == notes.count && !notes.contains(""))
        #expect(ScrollUnreadableStretch.Refusal.galleryLatched.note == "gallery latched")
    }

    @Test func jerksAndTheirChecksAreNotAStretchAndAreNotDecidedAtAll() {
        var stretch = ScrollUnreadableStretch()
        stretch.begin()
        #expect(stretch.decide(situation()) == .save)
        stretch.jerkNotPlaced()
        #expect(stretch.decide(situation()) == .save)
        stretch.placed()
        #expect(stretch.decide(situation()) == .series)
    }

    @Test func theSeventhStretchEndsTheCapture() {
        var stretch = ScrollUnreadableStretch()
        #expect(ScrollUnreadableStretch.stretchLimit == 6)
        for met in 1...ScrollUnreadableStretch.stretchLimit {
            #expect(stretch.decide(situation()) == .series)
            stretch.begin()
            stretch.placed()
            #expect(stretch.stretches == met)
        }
        #expect(stretch.decide(situation()) == .tooMany)
        #expect(stretch.decide(situation(.standing(count: 3, queued: 2))) == .tooMany)
        // Past the ceiling, what is no stretch stays an ordinary end.
        #expect(stretch.decide(situation(changes: false)) == .save)
        #expect(stretch.decide(situation(.queueFull(queued: 3))) == .save)
    }

    // MARK: Which frames

    @Test func upToThreeFramesAreTakenAndTheRestAreLeftOut() {
        func series(_ count: Int) -> [Int] { ScrollUnreadableStretch.series(count: count) { _, _ in false } }
        #expect(ScrollUnreadableStretch.seriesLimit == 3)
        #expect(series(0) == [])
        #expect(series(1) == [0])
        #expect(series(2) == [0, 1])
        #expect(series(3) == [0, 1, 2])
        #expect(series(4) == [0, 2, 3])
        // Eight waiting and the current one, as in 2026-10-18-233440 steps 28–36.
        #expect(series(9) == [0, 4, 8])
        #expect(series(8) == [0, 4, 7])
    }

    @Test func aFrameThatShowsAPageAlreadyTakenIsLeftOut() {
        // Frames 0 and 1 are one page; 2 and 3 are another.
        func same(_ a: Int, _ b: Int) -> Bool { a >= 0 && (a / 2) == (b / 2) }
        #expect(ScrollUnreadableStretch.series(count: 4, same: same) == [0, 2])
        #expect(ScrollUnreadableStretch.series(count: 3, same: same) == [0, 2])
        // Everything is one page: the first is taken, and nothing more.
        #expect(ScrollUnreadableStretch.series(count: 9, same: { a, _ in a >= 0 }) == [0])
    }

    @Test func aFrameThatShowsTheLastFrameLaidIsLeftOut() {
        // `same(-1, i)` asks about the last frame laid.
        func same(_ a: Int, _ b: Int) -> Bool { a == -1 && b == 0 }
        #expect(ScrollUnreadableStretch.series(count: 3, same: same) == [1, 2])
        #expect(ScrollUnreadableStretch.series(count: 1, same: same) == [])
    }

    @Test func theGuardsOwnSightDecidesWhatIsTheSamePage() {
        func frame(_ seed: Int, flat: Bool = false) -> CaptureFrame {
            let width = 128, height = 128
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let value = flat ? 100 : 30 + (x * 13 + y * 7 + seed * 43) % 170
                    for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = UInt8(value) }
                }
            }
            return CaptureFrame(width: width, height: height, pixels: pixels)
        }
        #expect(ScrollRepeatGuard.isSamePage(frame(0), frame(0)))
        #expect(!ScrollRepeatGuard.isSamePage(frame(0), frame(1)))
        // Flat frames are one page to this, and are never a repeat.
        #expect(ScrollRepeatGuard.isSamePage(frame(0, flat: true), frame(1, flat: true)))
    }

    // MARK: Jerks and their checks

    @Test func aJerkThatIsNotPlacedIsFollowedByACheckAndNothingElseHasOne() {
        var stretch = ScrollUnreadableStretch()
        #expect(stretch.phase == .off)
        stretch.jerkNotPlaced()
        #expect(stretch.phase == .off)
        stretch.begin()
        #expect(stretch.phase == .jerk && stretch.isJerking && !stretch.isChecking)
        #expect(stretch.jerks == 0 && stretch.stretches == 1)
        stretch.jerkNotPlaced()
        #expect(stretch.phase == .check && stretch.isChecking && !stretch.isJerking)
        // A check is not a jerk, and a second not-placed jerk does not move it on.
        stretch.jerkNotPlaced()
        #expect(stretch.phase == .check)
    }

    @Test func aCheckThatMovesThePageEndsTheJerks() {
        var stretch = ScrollUnreadableStretch()
        stretch.begin()
        stretch.jerkNotPlaced()
        #expect(stretch.checked(movesPage: false) == .stands)
        #expect(stretch.jerks == 1 && stretch.phase == .jerk)
        stretch.jerkNotPlaced()
        #expect(stretch.checked(movesPage: true) == .moves)
        #expect(stretch.phase == .off && stretch.jerks == 0)
        // Nothing waits for a check outside one.
        #expect(stretch.checked(movesPage: true) == .stands)
        #expect(stretch.phase == .off && stretch.jerks == 0)
    }

    @Test func fourChecksThatShowThePageStandingEndTheJerksAtTheLastOne() {
        var stretch = ScrollUnreadableStretch()
        #expect(ScrollUnreadableStretch.jerkLimit == 4)
        stretch.begin()
        for standing in 1..<ScrollUnreadableStretch.jerkLimit {
            stretch.jerkNotPlaced()
            #expect(stretch.checked(movesPage: false) == .stands)
            #expect(stretch.jerks == standing && stretch.isJerking)
        }
        stretch.jerkNotPlaced()
        #expect(stretch.checked(movesPage: false) == .ceiling)
        #expect(stretch.phase == .off && stretch.jerks == ScrollUnreadableStretch.jerkLimit)
        // Ordinary steps go on; the stretches met stay counted.
        #expect(stretch.stretches == 1)
    }

    @Test func aPlacedStepOrANewStretchStartsTheCountAgain() {
        var stretch = ScrollUnreadableStretch()
        stretch.begin()
        stretch.jerkNotPlaced()
        stretch.checked(movesPage: false)
        stretch.jerkNotPlaced()
        stretch.checked(movesPage: false)
        stretch.placed()
        #expect(stretch.phase == .off && stretch.jerks == 0)
        stretch.begin()
        #expect(stretch.isJerking && stretch.jerks == 0 && stretch.stretches == 2)
        // The four are counted from the stretch, not from the capture.
        for _ in 1..<ScrollUnreadableStretch.jerkLimit {
            stretch.jerkNotPlaced()
            #expect(stretch.checked(movesPage: false) == .stands)
        }
        stretch.jerkNotPlaced()
        #expect(stretch.checked(movesPage: false) == .ceiling)
    }

    private func jerking() -> ScrollUnreadableStretch {
        var stretch = ScrollUnreadableStretch()
        stretch.begin()
        stretch.jerkNotPlaced()
        return stretch
    }

    @Test func aCheckThatThePlacementOrTheTilesBearOutMovesThePage() {
        // Placed by the matcher — a second look that matched counts as placed, as it does everywhere.
        var placed = jerking()
        #expect(placed.afterCheck(placed: true, decision: nil) == .jerkThenPlaced)
        #expect(placed.phase == .off && placed.jerks == 0)
        // Not placed, but the tiles bear out the distance of the step.
        var confirmed = jerking()
        #expect(confirmed.afterCheck(placed: false, decision: .temporary(confirmed: true)) == .jerkThenConfirmed)
        #expect(confirmed.phase == .off && confirmed.jerks == 0)
    }

    @Test func everyOtherCheckShowsThePageStandingAndTheNextJerkGoesOn() {
        let decisions: [ScrollStepDecision?] = [.temporary(confirmed: false), .stationary, .retry, .finish, nil]
        for decision in decisions {
            var stretch = jerking()
            #expect(stretch.afterCheck(placed: false, decision: decision) == .nextJerk)
            #expect(stretch.phase == .jerk && stretch.jerks == 1)
        }
    }

    @Test func theFourthCheckThatShowsThePageStandingIsTheCeiling() {
        var stretch = jerking()
        for _ in 1..<ScrollUnreadableStretch.jerkLimit {
            #expect(stretch.afterCheck(placed: false, decision: .stationary) == .nextJerk)
            stretch.jerkNotPlaced()
        }
        #expect(stretch.afterCheck(placed: false, decision: .stationary) == .ceiling)
        #expect(stretch.phase == .off)
        // The page moving in the fourth is not the ceiling.
        var moving = jerking()
        for _ in 1..<ScrollUnreadableStretch.jerkLimit {
            moving.afterCheck(placed: false, decision: .stationary)
            moving.jerkNotPlaced()
        }
        #expect(moving.afterCheck(placed: true, decision: nil) == .jerkThenPlaced)
    }

    @Test func aJerkFrameThatRepeatsAPageAlreadyLeftIsNeitherLaidNorAGroundForLayingTheCheck() {
        #expect(ScrollUnreadableStretch.jerkFrame(anotherScreen: true, isRepeat: false) == .lay)
        #expect(ScrollUnreadableStretch.jerkFrame(anotherScreen: true, isRepeat: true) == .repeatsPageLeft)
        // Nearly the frame laid: nothing to lay, and the check goes on after that frame as it was.
        #expect(ScrollUnreadableStretch.jerkFrame(anotherScreen: false, isRepeat: false) == .thePageLaid)
        #expect(ScrollUnreadableStretch.jerkFrame(anotherScreen: false, isRepeat: true) == .thePageLaid)
    }

    @Test func aCheckThatMovesAfterARepeatingJerkFrameCountsAsThePageStanding() {
        // Placed by the matcher, or only borne out by the tiles: the check is not laid and not queued.
        let moving: [(Bool, ScrollStepDecision?)] = [(true, nil), (false, .temporary(confirmed: true))]
        for (placed, decision) in moving {
            var stretch = jerking()
            #expect(stretch.afterCheck(placed: placed, decision: decision, jerkRepeats: true) == .nextJerk)
            #expect(stretch.phase == .jerk && stretch.jerks == 1)
        }
        // It is counted: the fourth is the ceiling, as for a check that shows nothing moving.
        var stretch = jerking()
        for _ in 1..<ScrollUnreadableStretch.jerkLimit {
            #expect(stretch.afterCheck(placed: true, decision: nil, jerkRepeats: true) == .nextJerk)
            stretch.jerkNotPlaced()
        }
        #expect(stretch.afterCheck(placed: true, decision: nil, jerkRepeats: true) == .ceiling)
        #expect(stretch.phase == .off)
        // Without the repeat the same check moves the page.
        var plain = jerking()
        #expect(plain.afterCheck(placed: true, decision: nil, jerkRepeats: false) == .jerkThenPlaced)
    }

    @Test func aFrameIsLaidOnlyWhenItIsAnotherScreenAndNotARepeat() {
        #expect(ScrollUnreadableStretch.laysFrame(anotherScreen: true, isRepeat: false))
        #expect(!ScrollUnreadableStretch.laysFrame(anotherScreen: false, isRepeat: false))
        #expect(!ScrollUnreadableStretch.laysFrame(anotherScreen: true, isRepeat: true))
        #expect(!ScrollUnreadableStretch.laysFrame(anotherScreen: false, isRepeat: true))
    }

    @Test func theCheckAfterAJerkIsNoEvidenceForTheCalibration() {
        #expect(!ScrollStepPlacement.stretch.cleanStep)
        #expect(!ScrollStepPlacement.stretch.updatesCalibration)
    }

    // MARK: Laid edge to edge

    private func solid(_ value: UInt8, width: Int = 40, height: Int = 60) -> CaptureFrame {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for pixel in 0..<(width * height) {
            for channel in 0..<3 { pixels[pixel * 4 + channel] = value }
        }
        return CaptureFrame(width: width, height: height, pixels: pixels)
    }

    @Test func framesLaidEdgeToEdgeGrowTheImageByTheirLengthsAndNoMore() throws {
        var assembler = ImageAssembler(axis: .vertical)
        let a = solid(10), b = solid(120), c = solid(230)
        assembler.begin(with: a)
        #expect(assembler.fullLength == a.height)
        try assembler.appendEdgeToEdge(b)
        #expect(assembler.fullLength == a.height + b.height)
        try assembler.appendEdgeToEdge(c)
        #expect(assembler.fullLength == a.height + b.height + c.height)
        #expect(assembler.lastFrame == c)
        let image = try #require(CaptureFrame(image: try assembler.makeImage()))
        #expect(image.height == 3 * a.height)
        // A hard seam: each frame in whole, nothing of one in another.
        #expect(image[5, a.height - 1, 0] == 10 && image[5, a.height, 0] == 120)
        #expect(image[5, 2 * a.height - 1, 0] == 120 && image[5, 2 * a.height, 0] == 230)
        #expect(image[5, 0, 0] == 10 && image[5, image.height - 1, 0] == 230)
    }

    @Test func aStepThatOverlapsGoesOnFromAnEdgeToEdgeFrameAsEver() throws {
        var assembler = ImageAssembler(axis: .vertical)
        let a = solid(10), b = solid(120)
        assembler.begin(with: a)
        try assembler.appendEdgeToEdge(b)
        try assembler.append(solid(120), movement: 25)
        #expect(assembler.fullLength == a.height + b.height + 25)
    }

    @Test func onlyEdgeToEdgeMayHaveNoOverlapAndNeitherMaySkipAFrameOfAnotherSize() throws {
        var assembler = ImageAssembler(axis: .vertical)
        let a = solid(10)
        assembler.begin(with: a)
        #expect(throws: (any Error).self) { try assembler.append(solid(120), movement: a.height) }
        #expect(throws: (any Error).self) { try assembler.append(solid(120), movement: 0) }
        #expect(throws: (any Error).self) { try assembler.appendEdgeToEdge(solid(120, height: 61)) }
        #expect(assembler.fullLength == a.height)
        var empty = ImageAssembler(axis: .vertical)
        #expect(throws: (any Error).self) { try empty.appendEdgeToEdge(a) }
    }
}
