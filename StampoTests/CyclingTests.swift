import Foundation
import Testing
@testable import Stampo

/// ⇥ steps through four different lists on four surfaces. What they share is
/// this function, so the wrap — and especially the backwards wrap, which is
/// written as a forward step — is pinned here once rather than at each site.
@Suite struct CyclingTests {

    @Test func steppingForwardWrapsAtTheEnd() {
        let all = ColorSchemeType.allCases
        let last = try! #require(all.last)
        #expect(nextCase(after: all[0]) == all[1])
        #expect(nextCase(after: last) == all[0])
    }

    @Test func steppingBackWrapsAtTheStart() {
        let all = ColorSchemeType.allCases
        let last = try! #require(all.last)
        #expect(nextCase(after: all[0], backwards: true) == last)
        #expect(nextCase(after: all[1], backwards: true) == all[0])
    }

    @Test func aFullLapReturnsToWhereItStarted() {
        // The colour picker has five formats and the archive four; a lap that
        // did not close would leave one of them unreachable in one direction.
        for format in HUDColorFormat.allCases {
            var forward = format
            for _ in HUDColorFormat.allCases { forward = nextCase(after: forward) }
            #expect(forward == format)

            var back = format
            for _ in HUDColorFormat.allCases { back = nextCase(after: back, backwards: true) }
            #expect(back == format)
        }
    }

    @Test func forwardAndBackAreEachOthersUndo() {
        for scheme in ColorSchemeType.allCases {
            #expect(nextCase(after: nextCase(after: scheme), backwards: true) == scheme)
        }
    }
}
