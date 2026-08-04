import AppKit
import Foundation
import Testing
@testable import Stampo

/// The logic behind the archive's multi-select mode: what a stack's checkbox
/// adds up to, what the selection resolves to when it is shared or dragged, and
/// which cells a drag is allowed to start from.
@MainActor
@Suite struct ArchiveSelectionTests {

    private let shot = URL(fileURLWithPath: "/tmp/archive/shot.png")
    private let a = URL(fileURLWithPath: "/tmp/drop/a.pdf")
    private let b = URL(fileURLWithPath: "/tmp/drop/b.pdf")
    private let c = URL(fileURLWithPath: "/tmp/drop/c.pdf")

    private func color(_ hex: String) -> ArchiveColor {
        ArchiveColor(color: NSColor(hexString: hex)!, hex: hex)
    }

    // MARK: Tri-state

    @Test func anUntouchedStackIsEmpty() {
        let state = ArchiveSelectionState()
        #expect(state.checkState(forMembers: [a, b, c]) == .empty)
    }

    @Test func oneMemberMakesTheStackMixed() {
        let state = ArchiveSelectionState()
        state.toggle(.file(b))
        #expect(state.checkState(forMembers: [a, b, c]) == .mixed)
    }

    @Test func everyMemberMakesItFull() {
        let state = ArchiveSelectionState()
        state.setMembers([a, b, c], selected: true)
        #expect(state.checkState(forMembers: [a, b, c]) == .full)
    }

    /// Deselecting one member of a full stack is what puts the collapsed cell
    /// into the mixed state — the whole point of the members being selectable.
    @Test func deselectingOneMemberDropsTheStackToMixed() {
        let state = ArchiveSelectionState()
        state.setMembers([a, b, c], selected: true)
        state.toggle(.file(b))
        #expect(state.checkState(forMembers: [a, b, c]) == .mixed)
    }

    /// The trap this mode is easiest to get wrong on: an expanded stack renders
    /// only up to a cap and sends the rest to a "+N" tail, so a check computed
    /// over the *rendered* members would show a fully selected stack as mixed.
    /// Selecting every member — cap or no cap — must read as full.
    @Test func theCheckCoversMembersTheRowNeverRenders() {
        let members = (0..<80).map { URL(fileURLWithPath: "/tmp/drop/\($0).pdf") }
        let state = ArchiveSelectionState()
        state.setMembers(members, selected: true)
        #expect(state.checkState(forMembers: members) == .full)

        // …and one hidden member left out is enough to make it mixed.
        state.toggle(.file(members[75]))
        #expect(state.checkState(forMembers: members) == .mixed)
    }

    @Test func anEmptyStackHasNothingToBeFullOf() {
        #expect(ArchiveSelectionState().checkState(forMembers: []) == .empty)
    }

    // MARK: The stack checkbox's action

    @Test func theStackCheckboxFillsFromEmpty() {
        let state = ArchiveSelectionState()
        state.toggleMembers([a, b, c])
        #expect(state.checkState(forMembers: [a, b, c]) == .full)
    }

    /// Mixed completes rather than empties: a half-filled box promises that one
    /// more click fills it.
    @Test func theStackCheckboxFillsFromMixed() {
        let state = ArchiveSelectionState()
        state.toggle(.file(a))
        state.toggleMembers([a, b, c])
        #expect(state.checkState(forMembers: [a, b, c]) == .full)
    }

    @Test func theStackCheckboxEmptiesFromFull() {
        let state = ArchiveSelectionState()
        state.setMembers([a, b, c], selected: true)
        state.toggleMembers([a, b, c])
        #expect(state.checkState(forMembers: [a, b, c]) == .empty)
    }

    /// One stack's checkbox must not reach into another's members.
    @Test func fillingOneStackLeavesTheOtherAlone() {
        let other = URL(fileURLWithPath: "/tmp/elsewhere/x.pdf")
        let state = ArchiveSelectionState()
        state.toggleMembers([a, b])
        #expect(state.checkState(forMembers: [other]) == .empty)
    }

    // MARK: What the selection resolves to

    @Test func nothingSelectedResolvesToNothing() {
        let items: [ArchiveItem] = [.screenshot(ArchiveScreenshot(url: shot)),
                                    .stack(ArchiveStack(urls: [a, b]))]
        #expect(ArchiveSelectionState().selectedItems(in: items).isEmpty)
    }

    @Test func leavesResolveToThemselvesInDisplayOrder() {
        let red = color("#FF0000")
        let text = ArchiveText(text: "hello")
        let capture = ArchiveScreenshot(url: shot)
        let items: [ArchiveItem] = [.screenshot(capture), .text(text), .color(red)]

        let state = ArchiveSelectionState()
        state.toggle(.item(red.id))
        state.toggle(.item(capture.id))

        #expect(NotchArchiveModel.payload(for: state.selectedItems(in: items),
                                          colorScheme: .hex)
                == [.file(shot), .string("#FF0000")])
    }

    /// The reason the keys are leaves: a partly selected stack shares exactly
    /// the members that are checked, not the pile it belongs to.
    @Test func aPartlySelectedStackContributesOnlyItsCheckedMembers() {
        let items: [ArchiveItem] = [.stack(ArchiveStack(urls: [a, b, c]))]
        let state = ArchiveSelectionState()
        state.setMembers([a, c], selected: true)

        #expect(NotchArchiveModel.payload(for: state.selectedItems(in: items),
                                          colorScheme: .hex)
                == [.file(a), .file(c)])
    }

    @Test func anUntouchedStackContributesNothing() {
        let capture = ArchiveScreenshot(url: shot)
        let items: [ArchiveItem] = [.stack(ArchiveStack(urls: [a, b])), .screenshot(capture)]
        let state = ArchiveSelectionState()
        state.toggle(.item(capture.id))

        #expect(state.selectedItems(in: items).count == 1)
        #expect(NotchArchiveModel.payload(for: state.selectedItems(in: items),
                                          colorScheme: .hex) == [.file(shot)])
    }

    /// Colours resolve through the header's notation — the selection changes
    /// what is shared, never how.
    @Test func selectedColorsUseTheArchivesNotation() {
        let red = color("#FF0000")
        let state = ArchiveSelectionState()
        state.toggle(.item(red.id))
        #expect(NotchArchiveModel.payload(for: state.selectedItems(in: [.color(red)]),
                                          colorScheme: .rgb)
                == [.string(red.color.rgbString)])
    }

    /// A key whose item left the archive (a watched file vanished) resolves to
    /// nothing rather than to a stale entry.
    @Test func keysForVanishedItemsDropOut() {
        let gone = ArchiveScreenshot(url: shot)
        let state = ArchiveSelectionState()
        state.toggle(.item(gone.id))
        state.toggle(.file(a))
        #expect(state.selectedItems(in: []).isEmpty)
    }

    // MARK: Select All

    @Test func selectAllPicksLeavesAndEveryStackMember() {
        let red = color("#FF0000")
        let capture = ArchiveScreenshot(url: shot)
        let items: [ArchiveItem] = [.color(red), .stack(ArchiveStack(urls: [a, b, c])),
                                    .screenshot(capture)]
        let state = ArchiveSelectionState()
        state.selectAll(in: items)
        #expect(state.contains(.item(red.id)))
        #expect(state.contains(.item(capture.id)))
        #expect(state.checkState(forMembers: [a, b, c]) == .full)
        #expect(state.isEverythingSelected(in: items))
    }

    @Test func oneMissingMemberIsNotEverything() {
        let items: [ArchiveItem] = [.stack(ArchiveStack(urls: [a, b, c]))]
        let state = ArchiveSelectionState()
        state.setMembers([a, b], selected: true)
        #expect(!state.isEverythingSelected(in: items))
    }

    /// An empty archive has nothing to pick, which is not the same as having
    /// picked everything.
    @Test func anEmptyArchiveIsNotEverythingSelected() {
        #expect(!ArchiveSelectionState().isEverythingSelected(in: []))
    }

    /// …and that difference is exactly why the menu asks `canSelectAll` instead
    /// of negating the line above: on an empty archive the negation says yes,
    /// and the row would be live with nothing to add.
    @Test func thereIsNothingToSelectInAnEmptyArchive() {
        #expect(!ArchiveSelectionState().canSelectAll(in: []))
    }

    @Test func selectAllIsOfferedWhileSomethingIsUnpicked() {
        let items: [ArchiveItem] = [.stack(ArchiveStack(urls: [a, b]))]
        let state = ArchiveSelectionState()
        #expect(state.canSelectAll(in: items))
        state.setMembers([a], selected: true)
        #expect(state.canSelectAll(in: items))
        state.setMembers([b], selected: true)
        #expect(!state.canSelectAll(in: items))
    }

    // MARK: Which cells a drag may start from

    @Test func outsideTheModeEveryCellDrags() {
        let state = ArchiveSelectionState()
        #expect(state.allowsDrag(from: .file(a)))
        #expect(state.allowsDrag(fromMembers: [a, b]))
    }

    @Test func inTheModeOnlyASelectedCellDrags() {
        let state = ArchiveSelectionState()
        state.isActive = true
        state.toggle(.file(a))
        #expect(state.allowsDrag(from: .file(a)))
        #expect(!state.allowsDrag(from: .file(b)))
    }

    /// A collapsed stack drags as soon as any member is checked — mixed is
    /// still visibly part of the selection.
    @Test func aMixedStackDrags() {
        let state = ArchiveSelectionState()
        state.isActive = true
        state.toggle(.file(a))
        #expect(state.allowsDrag(fromMembers: [a, b, c]))
    }

    @Test func anEmptyStackDoesNotDrag() {
        let state = ArchiveSelectionState()
        state.isActive = true
        state.toggle(.file(a))
        #expect(!state.allowsDrag(fromMembers: [b, c]))
    }

    // MARK: Entering from a cell

    /// A cell's own "Select" both turns the mode on and picks the cell — the
    /// user already pointed at it by right-clicking.
    @Test func aCellsMenuEntersTheModeWithThatCellPicked() {
        let capture = ArchiveScreenshot(url: shot)
        let state = ArchiveSelectionState()
        state.begin(selecting: .item(capture.id))
        #expect(state.isActive)
        #expect(state.contains(.item(capture.id)))
    }

    @Test func aStacksMenuEntersTheModeWithEveryMemberPicked() {
        let state = ArchiveSelectionState()
        state.begin(selectingMembers: [a, b, c])
        #expect(state.isActive)
        #expect(state.checkState(forMembers: [a, b, c]) == .full)
    }

    /// Entering from a second cell adds to what is picked instead of replacing
    /// it — the mode is already on, and the menu is just another way to check a
    /// box.
    @Test func enteringAgainAddsRatherThanReplaces() {
        let state = ArchiveSelectionState()
        state.begin(selecting: .file(a))
        state.begin(selecting: .file(b))
        #expect(state.keys == [.file(a), .file(b)])
    }

    // MARK: Leaving the mode

    @Test func clearingLeavesTheModeAndForgetsTheSelection() {
        let state = ArchiveSelectionState()
        state.isActive = true
        state.setMembers([a, b], selected: true)
        state.clear()
        #expect(!state.isActive)
        #expect(state.keys.isEmpty)
    }

    /// Emptying the selection is not leaving the mode: the "⋯" menu enters it
    /// with nothing selected, so an empty set has to be a state it can rest in.
    @Test func deselectingTheLastCellStaysInTheMode() {
        let state = ArchiveSelectionState()
        state.isActive = true
        state.toggle(.file(a))
        state.toggle(.file(a))
        #expect(state.keys.isEmpty)
        #expect(state.isActive)
    }
}
