import CoreGraphics
import Testing
@testable import Stampo

@Suite struct ScrollDirectionHintTests {
    private let window = CGRect(x: 100, y: 50, width: 800, height: 600)

    @Test func scrollbarsContributeTheirOwnAxesAcrossSuitableAncestors() {
        let vertical = ScrollAncestorCandidate(identity: 0, role: "AXTable", frame: window,
                                               hasVerticalScrollBar: true)
        let horizontal = ScrollAncestorCandidate(identity: 1, role: "AXScrollArea", frame: window,
                                                 hasHorizontalScrollBar: true)
        #expect(ScrollDirectionHint.possibleAxes(ancestors: [vertical], windowBounds: window) == [.vertical])
        #expect(ScrollDirectionHint.possibleAxes(ancestors: [horizontal], windowBounds: window) == [.horizontal])
        #expect(ScrollDirectionHint.possibleAxes(ancestors: [vertical, horizontal], windowBounds: window)
                == [.vertical, .horizontal])
    }

    @Test func aWebAreaContributesVerticalEvenWithoutAScrollbar() {
        let web = ScrollAncestorCandidate(identity: 0, role: "AXWebArea", frame: window)
        #expect(ScrollDirectionHint.possibleAxes(ancestors: [web], windowBounds: window) == [.vertical])
        let wideWeb = ScrollAncestorCandidate(identity: 1, role: "AXWebArea", frame: window,
                                              hasHorizontalScrollBar: true)
        #expect(ScrollDirectionHint.possibleAxes(ancestors: [wideWeb], windowBounds: window)
                == [.vertical, .horizontal])
    }

    @Test func unsuitableRolesAndFramesDoNotContributeAxes() {
        let group = ScrollAncestorCandidate(identity: 0, role: "AXGroup", frame: window,
                                            hasHorizontalScrollBar: true, hasVerticalScrollBar: true)
        let small = ScrollAncestorCandidate(identity: 1, role: "AXWebArea",
                                            frame: CGRect(x: 100, y: 50, width: 79, height: 100))
        let outside = ScrollAncestorCandidate(identity: 2, role: "AXScrollArea",
                                              frame: window.offsetBy(dx: 1000, dy: 0),
                                              hasHorizontalScrollBar: true, hasVerticalScrollBar: true)
        #expect(ScrollDirectionHint.possibleAxes(ancestors: [group, small, outside], windowBounds: window).isEmpty)
    }

    @Test func emptyOrUnmarkedAncestorsContributeNoAxes() {
        #expect(ScrollDirectionHint.possibleAxes(ancestors: [], windowBounds: window).isEmpty)
        let area = ScrollAncestorCandidate(identity: 0, role: "AXScrollArea", frame: window)
        #expect(ScrollDirectionHint.possibleAxes(ancestors: [area], windowBounds: window).isEmpty)
    }

    @Test(arguments: [ScrollDirection.down, .right])
    func shownUsesASingleAxisAndOtherwiseKeepsTheSetting(setting: ScrollDirection) {
        #expect(ScrollDirectionHint.shown(possible: [.vertical], setting: setting) == .down)
        #expect(ScrollDirectionHint.shown(possible: [.horizontal], setting: setting) == .right)
        #expect(ScrollDirectionHint.shown(possible: [.vertical, .horizontal], setting: setting) == setting)
        #expect(ScrollDirectionHint.shown(possible: [], setting: setting) == setting)
        #expect(ScrollDirectionHint.shown(possible: nil, setting: setting) == setting)
    }

    @Test(arguments: [ScrollDirection.down, .right])
    func turnedKeepsTheSettingForASingleAxisAndOtherwiseTurnsIt(setting: ScrollDirection) {
        #expect(ScrollDirectionHint.turned(setting: setting, possible: [.vertical]) == setting)
        #expect(ScrollDirectionHint.turned(setting: setting, possible: [.horizontal]) == setting)
        #expect(ScrollDirectionHint.turned(setting: setting, possible: [.vertical, .horizontal]) == setting.other)
        #expect(ScrollDirectionHint.turned(setting: setting, possible: []) == setting.other)
        #expect(ScrollDirectionHint.turned(setting: setting, possible: nil) == setting.other)
    }
}
