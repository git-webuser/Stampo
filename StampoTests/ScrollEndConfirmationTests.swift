import Testing
@testable import Stampo

/// The last standing step may be a pinned section, including after an ordinary
/// push was undone. Only a confirming push spends the attempt until the image grows.
@Suite struct ScrollEndConfirmationTests {
    typealias Action = ScrollPush.StandingAction
    typealias Refusal = ScrollUnreadableStretch.Refusal

    private func action(_ count: Int, empty: Bool = true, allowed: Bool = true,
                        used: Bool = false, refusal: Refusal? = nil, gallery: Bool = false) -> Action {
        ScrollPush.afterStanding(zeroMotionCount: count, queueIsEmpty: empty, allowed: allowed,
                                 endPushUsed: used, stretchRefusal: refusal, galleryActive: gallery)
    }

    @Test func beforeTheSecondStandingStepNothingStarts() {
        for count in [-1, 0, 1] {
            for empty in [false, true] {
                for allowed in [false, true] {
                    for used in [false, true] {
                        #expect(action(count, empty: empty, allowed: allowed, used: used) == .wait)
                    }
                }
            }
        }
    }

    @Test func theSecondStandingStepKeepsTheOrdinaryPushRestrictions() {
        for empty in [false, true] {
            for allowed in [false, true] {
                let expected: Action = empty && allowed ? .push : .wait
                for used in [false, true] {
                    #expect(action(2, empty: empty, allowed: allowed, used: used) == expected)
                }
                #expect(ScrollPush.startsPush(zeroMotionCount: 2, queueIsEmpty: empty, allowed: allowed)
                        == (expected == .push))
            }
        }
    }

    @Test func theThirdStandingStepConfirmsOnceRegardlessOfTheQueueAndPermission() {
        for count in [3, 4, 9] {
            for empty in [false, true] {
                for allowed in [false, true] {
                    #expect(action(count, empty: empty, allowed: allowed,
                                   refusal: .framesDoNotChange) == .confirmEnd)
                    #expect(action(count, empty: empty, allowed: allowed, used: true,
                                   refusal: .framesDoNotChange) == .finish)
                }
            }
        }
    }

    @Test func onlyAQueueShowingThePageAlreadyLaidMayBeDroppedForConfirmation() {
        // A missing laid base or a series that chose no frames may leave no refusal; neither opens a push path.
        let cases: [(Refusal?, Action)] = [
            (.framesDoNotChange, .confirmEnd),
            (.notVertical, .finish), (.galleryLatched, .finish), (.pushing, .finish),
            (.underway, .finish), (.repeatsPage, .finish), (.queueNotFull, .finish),
            (.notStandingLongEnough, .finish), (.nothingPlacedSince, .finish), (nil, .finish)
        ]
        for (refusal, expected) in cases {
            for count in [3, 4] {
                for allowed in [false, true] {
                    #expect(action(count, empty: false, allowed: allowed, refusal: refusal) == expected)
                    #expect(action(count, empty: false, allowed: allowed, used: true,
                                   refusal: refusal) == .finish)
                }
            }
        }
    }

    @Test func anEmptyQueueNeedsNoStretchRefusalBeforeItConfirms() {
        for allowed in [false, true] {
            #expect(action(3, allowed: allowed) == .confirmEnd)
            #expect(action(3, allowed: allowed, used: true) == .finish)
        }
    }

    @Test func anActiveGalleryKeepsBothPushesFromStarting() {
        for empty in [false, true] {
            for allowed in [false, true] {
                for used in [false, true] {
                    #expect(action(2, empty: empty, allowed: allowed, used: used,
                                   refusal: .framesDoNotChange, gallery: true) == .wait)
                    for count in [3, 4] {
                        #expect(action(count, empty: empty, allowed: allowed, used: used,
                                       refusal: .framesDoNotChange, gallery: true) == .finish)
                    }
                }
            }
        }
    }

    /// 2026-10-19-133530, steps 12–16: an ordinary push was undone, leaving an
    /// empty queue and pushes forbidden. It must still get one confirmation.
    @Test func anOrdinaryPushAndItsUndoDoNotSpendTheConfirmation() {
        var confirmation = ScrollPush.EndConfirmation()
        #expect(!confirmation.used)
        #expect(action(2, used: confirmation.used) == .push)
        let pushed = ScrollPush.next(mode: .push, outcome: .stationary(changed: true))
        #expect(pushed == ScrollPush.Step(action: .check, mode: .check(pushes: 1)))
        #expect(ScrollPush.afterMovingCheck(offset: 35, expected: 400, confidence: 0.75,
                                           mode: pushed.mode) == .undo)
        #expect(!confirmation.used)
        #expect(action(2, allowed: false, used: confirmation.used) == .wait)
        #expect(action(3, allowed: false, used: confirmation.used) == .confirmEnd)
        confirmation.start()
        #expect(confirmation.used)
    }

    @Test func undoingTheConfirmationDoesNotRenewIt() {
        var confirmation = ScrollPush.EndConfirmation()
        #expect(action(3, allowed: false, used: confirmation.used) == .confirmEnd)
        confirmation.start()
        let pushed = ScrollPush.next(mode: .push, outcome: .stationary(changed: true))
        let checked = ScrollPush.afterCheck(mode: pushed.mode, movesPage: true)
        #expect(checked == ScrollPush.Step(action: .undo, mode: .none))
        #expect(confirmation.used)
        for count in [3, 4, 6] {
            #expect(action(count, allowed: false, used: confirmation.used) == .finish)
            #expect(action(count, empty: false, allowed: false, used: confirmation.used,
                           refusal: .framesDoNotChange) == .finish)
        }
    }

    @Test func restartingTheStandingCountWithoutGrowingTheImageDoesNotRenewTheAttempt() {
        var confirmation = ScrollPush.EndConfirmation()
        confirmation.start()
        // A temporary step can reset the standing count without putting a frame into the image.
        let temporary = ScrollStepDecision.temporary(confirmed: true)
        #expect(ScrollPush.movesPage(placed: false, decision: temporary))
        #expect(action(0, allowed: false, used: confirmation.used) == .wait)
        // Nor does a stretch renew it when every candidate was left out.
        let chosen = ScrollUnreadableStretch.series(count: 1, same: { _, _ in true })
        #expect(chosen.isEmpty)
        #expect(!ScrollUnreadableStretch.laysCurrentFrame(chosen: chosen, count: 1))
        for count in 1...2 {
            #expect(action(count, allowed: false, used: confirmation.used) == .wait)
        }
        #expect(confirmation.used)
        #expect(action(3, allowed: false, used: confirmation.used) == .finish)
    }

    @Test func onlyAppendingAFrameRenewsTheConfirmation() {
        let cases: [(ScrollPush.EndConfirmation.Placement, Bool, Bool)] = [
            (.append, false, false), (.append, true, false),
            (.replace, false, false), (.replace, true, true)
        ]
        for (placement, usedBefore, usedAfter) in cases {
            var confirmation = ScrollPush.EndConfirmation()
            if usedBefore { confirmation.start() }
            confirmation.placedFrame(placement)
            #expect(confirmation.used == usedAfter)
            let expected: Action = usedAfter ? .finish : .confirmEnd
            #expect(action(3, allowed: false, used: confirmation.used) == expected)
        }
    }

    @Test func aSectionThatReplacesAStageAndReturnsWithoutGrowthCannotConfirmAgain() {
        var confirmation = ScrollPush.EndConfirmation()
        #expect(action(3, allowed: false, used: confirmation.used) == .confirmEnd)
        confirmation.start()
        let pushed = ScrollPush.next(mode: .push, outcome: .stationary(changed: true))
        let replaced = ScrollPush.afterCheck(mode: pushed.mode, movesPage: false)
        #expect(replaced == ScrollPush.Step(action: .replace, mode: .section(pushes: 1)))
        confirmation.placedFrame(.replace)
        #expect(confirmation.used)
        let sectionPush = ScrollPush.next(mode: replaced.mode, outcome: .stationary(changed: true))
        #expect(sectionPush == ScrollPush.Step(action: .check, mode: .check(pushes: 2)))
        // A firm check moving a whole step undoes the push and returns into the section.
        #expect(ScrollPush.afterMovingCheck(offset: 800, expected: 800, confidence: 0.98,
                                           mode: sectionPush.mode) == .undo)
        #expect(action(3, allowed: false, used: confirmation.used) == .finish)
        confirmation.placedFrame(.append)
        #expect(!confirmation.used)
        #expect(action(3, allowed: false, used: confirmation.used) == .confirmEnd)
    }

    @Test func aConfirmationUsesTheExistingQuietAndChangedPushOutcomes() {
        #expect(action(3, allowed: false) == .confirmEnd)
        let quiet = ScrollPush.next(mode: .push, outcome: .stationary(changed: false))
        #expect(quiet == ScrollPush.Step(action: .end, mode: .none))
        let changed = ScrollPush.next(mode: .push, outcome: .stationary(changed: true))
        #expect(changed == ScrollPush.Step(action: .check, mode: .check(pushes: 1)))
        #expect(ScrollPush.afterCheck(mode: changed.mode, movesPage: false)
                == ScrollPush.Step(action: .replace, mode: .section(pushes: 1)))
        #expect(ScrollPush.next(mode: .push, outcome: .placed)
                == ScrollPush.Step(action: .proceed, mode: .none))
    }

    /// 2026-10-14-214945 step 45 and 2026-10-20-004706 step 58: one frame waits,
    /// but its difference from the laid page is too small for T2 to lay a stretch.
    @Test func theRecordedQueuesThatShowTheLaidPageNowReachAConfirmation() {
        for difference in [0.0062, 0.0381] {
            let stretch = ScrollUnreadableStretch()
            let situation = ScrollUnreadableStretch.Situation(
                trigger: .standing(count: 3, queued: 1), isVertical: true,
                galleryActive: false, pushing: false,
                framesChange: ScrollUnreadableStretch.isAnotherScreen(difference: difference),
                isRepeat: false
            )
            #expect(stretch.decide(situation) == .save)
            let refusal = stretch.refusal(situation)
            #expect(refusal == .framesDoNotChange)
            // Both recordings laid a frame before this queue, so ordinary pushes were allowed.
            #expect(action(2, empty: false) == .wait)
            #expect(action(3, empty: false, refusal: refusal) == .confirmEnd)
        }
    }

    /// A queued frame at another place can contaminate the old mask. This checks the clean stationary
    /// value and push judgement; the private session assignment after discarding the queue is checked by review.
    @Test func aFreshStandingFrameDoesNotMaskAChangeFromTheDiscardedQueue() throws {
        let size = ScrollStillness.grid
        let pixels = [UInt8](repeating: 100, count: size * size * 4)
        let next = CaptureFrame(width: size, height: size, pixels: pixels)
        var queuedPixels = pixels
        for channel in 0..<3 { queuedPixels[15 * 4 + channel] = 105 }
        let queued = CaptureFrame(width: size, height: size, pixels: queuedPixels)
        let contaminated = StationaryFrame.after(step: next, kept: queued, previous: nil)
        #expect(contaminated.ownMotion == [15])
        let fresh = StationaryFrame(frame: next)
        #expect(fresh.frame == next)
        #expect(fresh.ownMotion.isEmpty)
        let pushTiles = try #require(ScrollStillness.tileDifferences(next, queued))
        #expect(ScrollPush.changedBesidesOwnMotion(push: pushTiles, ownMotion: contaminated.ownMotion) == false)
        #expect(ScrollPush.changedBesidesOwnMotion(push: pushTiles, ownMotion: fresh.ownMotion) == true)
    }
}
