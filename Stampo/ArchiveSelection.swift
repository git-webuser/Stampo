import Foundation

// MARK: - Selection key

/// One thing the archive's selection mode can hold.
///
/// Leaf-based rather than a set of archive items, because a stack stops being
/// atomic here: its members are selectable one at a time, so a stack is only
/// ever present through them. That also means the set maps straight onto
/// `NotchArchiveModel.payload(for:colorScheme:)`, which already flattens stacks
/// into files — share, copy and drag all fall out of the same resolver instead
/// of each assembling their own idea of what "selected" means.
enum ArchiveSelectionKey: Hashable {
    /// A colour, a snippet or a capture — anything the archive holds whole.
    case item(UUID)
    /// One member of a stack.
    case file(URL)
}

// MARK: - Check state

/// How a checkbox draws. A leaf is on or off; a stack is whatever its members
/// add up to, and never stored — see `ArchiveSelectionState.checkState`.
enum ArchiveCheckState: Equatable {
    case empty
    case mixed
    case full
}

// MARK: - Unwinding

/// One rung of the archive's ladder: what a single "undo one step" press has
/// to undo right now.
///
/// The archive can be two layers deep — a stack expanded into an accordion,
/// inside a selection the user is halfway through making — and both Esc and the
/// back chevron climb down it one rung per press, innermost first. They part
/// only at the bottom, where there is nothing left inside the archive to undo:
/// Esc closes the panel, Back returns to Main. Shared so that being the same
/// ladder is structural rather than two switches that happen to agree.
enum ArchiveUnwindStep: Equatable {
    case collapseStack
    case exitSelection
    /// The archive is plain: whatever the caller does when it is done here.
    case leaveArchive
}

func archiveUnwindStep(hasExpandedStack: Bool, isSelecting: Bool) -> ArchiveUnwindStep {
    if hasExpandedStack { return .collapseStack }
    if isSelecting      { return .exitSelection }
    return .leaveArchive
}

// MARK: - What a click means

/// The two things a cell can be clicked for.
enum ArchiveTapIntent: Equatable {
    /// The cell's own action. It is a different one on every kind of cell —
    /// copy the colour, copy the snippet, open the capture, expand the stack.
    case activate
    /// Add the cell to the selection or take it out, turning the mode on first
    /// if it is off.
    case pick
}

/// Whether a cell is picked by a plain click while selecting.
enum ArchiveCellKind {
    /// A colour, a snippet, a capture, one member of a stack.
    case leaf
    /// A collapsed stack, whose click keeps opening its accordion.
    case stack
}

/// The whole click model in one place, because left click already means four
/// different things across these cells and a fifth rule spread over four call
/// sites would be a rule nobody could read.
///
/// ⌘ picks, always — the Mac gesture for adding to a selection, and the way
/// into the mode without going through a menu. Once the mode is on a plain
/// click picks too, except on a stack: its click opens the accordion, which is
/// where its members are, and a mis-click there costs nothing. Leaves give
/// their click up because theirs costs something — a capture would open in
/// Preview and take the panel down with it.
func archiveTapIntent(kind: ArchiveCellKind,
                      isSelecting: Bool,
                      isCommandHeld: Bool) -> ArchiveTapIntent {
    if isCommandHeld { return .pick }
    if isSelecting, kind == .leaf { return .pick }
    return .activate
}

// MARK: - Selection state

/// The archive's multi-select mode, held outside the view for the same reason
/// `ArchiveExpansionState` is: Esc is an application-wide hotkey, so the panel
/// controller has to be able to see the mode and switch it off. Ephemeral —
/// nothing here is persisted, and opening the archive always starts clean.
@Observable final class ArchiveSelectionState {
    /// Whether the archive is in selection mode at all.
    ///
    /// Explicit rather than inferred from `keys` being non-empty: the "⋯" menu
    /// enters the mode with nothing selected, and clearing the last checkbox
    /// must not drop the user out from under their own next click.
    var isActive = false

    private(set) var keys: Set<ArchiveSelectionKey> = []

    // MARK: Picking

    /// Picking a cell, from its context menu or from a ⌘-click. Turns the mode
    /// on first, so the same call works whether it is already running or this is
    /// the way in — and a fresh mode has nothing in it, so the toggle can only
    /// add. (The "⋯" menu's way in has no cell to point at and just sets
    /// `isActive`.)
    func pick(_ key: ArchiveSelectionKey) {
        isActive = true
        toggle(key)
    }

    /// The same for a stack, which is picked through its members.
    func pickMembers(_ urls: [URL]) {
        isActive = true
        toggleMembers(urls)
    }

    // MARK: Leaves

    func contains(_ key: ArchiveSelectionKey) -> Bool { keys.contains(key) }

    func toggle(_ key: ArchiveSelectionKey) {
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
    }

    // MARK: Stacks

    /// A stack's checkbox, derived from its members every time it is asked for.
    ///
    /// Callers must pass **every** member, not the ones on screen: an expanded
    /// stack renders only up to a cap and routes the rest to an overflow tail,
    /// so counting the visible ones would show a fully selected stack as mixed.
    func checkState(forMembers urls: [URL]) -> ArchiveCheckState {
        guard !urls.isEmpty else { return .empty }
        let selected = urls.reduce(into: 0) { count, url in
            if keys.contains(.file(url)) { count += 1 }
        }
        if selected == 0 { return .empty }
        return selected == urls.count ? .full : .mixed
    }

    /// The stack checkbox's action: a full stack empties, anything else fills.
    /// Mixed going to full (rather than to empty) matches every checkbox in the
    /// system — a half-filled box is a promise that one more click completes it.
    func toggleMembers(_ urls: [URL]) {
        setMembers(urls, selected: checkState(forMembers: urls) != .full)
    }

    func setMembers(_ urls: [URL], selected: Bool) {
        for url in urls {
            if selected { keys.insert(.file(url)) } else { keys.remove(.file(url)) }
        }
    }

    // MARK: Everything

    /// Picks the whole archive. Leaves by id, stacks member by member — the set
    /// only ever holds leaves, so "all" is spelled out rather than flagged.
    func selectAll(in items: [ArchiveItem]) {
        for item in items {
            if case .stack(let stack) = item {
                setMembers(stack.urls, selected: true)
            } else {
                keys.insert(.item(item.id))
            }
        }
    }

    /// Whether "Select All" has anything left to add — the question the menu
    /// actually asks. Spelled out here rather than negated at the call site:
    /// an empty archive is neither everything-picked nor anything to pick, and
    /// `!isEverythingSelected` answers that with a live row that does nothing.
    func canSelectAll(in items: [ArchiveItem]) -> Bool {
        !items.isEmpty && !isEverythingSelected(in: items)
    }

    /// Whether every entry is picked. An empty archive is not: it has nothing
    /// to pick, which is a different thing — see `canSelectAll`.
    func isEverythingSelected(in items: [ArchiveItem]) -> Bool {
        guard !items.isEmpty else { return false }
        return items.allSatisfy { item in
            if case .stack(let stack) = item {
                return checkState(forMembers: stack.urls) == .full
            }
            return keys.contains(.item(item.id))
        }
    }

    // MARK: Drag

    /// A drag carries the whole selection, so it may only start from a cell that
    /// is part of it. An unselected cell in the mode drags nothing at all —
    /// deliberately: an accidental drag must not cost the user the selection
    /// they were halfway through building.
    func allowsDrag(from key: ArchiveSelectionKey) -> Bool {
        !isActive || contains(key)
    }

    /// The same rule for a collapsed stack, which is "selected" as far as the
    /// user can see the moment any of its members is.
    func allowsDrag(fromMembers urls: [URL]) -> Bool {
        !isActive || checkState(forMembers: urls) != .empty
    }

    // MARK: Resolving

    /// What the selection actually refers to, in the archive's own display
    /// order, ready for `NotchArchiveModel.payload(for:colorScheme:)`.
    ///
    /// A partly selected stack contributes a stack of just the chosen members;
    /// an untouched one contributes nothing. Keys that no longer match anything
    /// (a watched file vanished while the mode was open) simply drop out here,
    /// which is why no separate pruning pass is needed.
    static func selectedItems(in items: [ArchiveItem],
                              keys: Set<ArchiveSelectionKey>) -> [ArchiveItem] {
        items.compactMap { item in
            switch item {
            case .color, .text, .screenshot:
                return keys.contains(.item(item.id)) ? item : nil
            case .stack(let stack):
                let kept = stack.urls.filter { keys.contains(.file($0)) }
                return kept.isEmpty ? nil : .stack(ArchiveStack(urls: kept))
            }
        }
    }

    func selectedItems(in items: [ArchiveItem]) -> [ArchiveItem] {
        Self.selectedItems(in: items, keys: keys)
    }

    /// How many things are picked, counted as leaves.
    ///
    /// Not `selectedItems.count`: that counts archive entries, and a stack is
    /// one entry however many of its members are checked — so picking a pile of
    /// twenty read as "1". The number has to be the one Copy, Share and a drag
    /// will actually carry, which is a stack's picked members one by one. It
    /// fans out exactly as `NotchArchiveModel.payload` does, since that is the
    /// list it is counting.
    func pickedCount(in items: [ArchiveItem]) -> Int {
        selectedItems(in: items).reduce(into: 0) { total, item in
            if case .stack(let stack) = item {
                total += stack.urls.count
            } else {
                total += 1
            }
        }
    }

    // MARK: Leaving

    /// Leaves the mode and forgets what was in it. One call, because the two
    /// halves have no meaning apart: nothing draws a selection once the mode
    /// is off, so a set left behind could only come back as a surprise.
    func clear() {
        isActive = false
        keys = []
    }
}
