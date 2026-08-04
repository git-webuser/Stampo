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

    // MARK: Entering

    /// Turning the mode on from a cell's own context menu. The cell that was
    /// right-clicked comes in selected: it is the one the user pointed at, and
    /// entering with an empty row would make them click it again to say so.
    /// (The "⋯" menu's way in has nothing to point at, and just sets `isActive`.)
    func begin(selecting key: ArchiveSelectionKey) {
        isActive = true
        keys.insert(key)
    }

    /// The same, from a stack's menu — a stack is chosen through its members.
    func begin(selectingMembers urls: [URL]) {
        isActive = true
        setMembers(urls, selected: true)
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

    /// Whether there is anything left for "Select All" to add. An empty archive
    /// has nothing to select, which is not the same as everything being picked.
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

    // MARK: Leaving

    /// Forgets the selection but stays in the mode — what a command that
    /// consumed the selection leaves behind. Deleting what was picked ends that
    /// round of picking, not the picking.
    func deselectAll() { keys = [] }

    /// Leaves the mode and forgets what was in it. One call, because the two
    /// halves have no meaning apart: nothing draws a selection once the mode
    /// is off, so a set left behind could only come back as a surprise.
    func clear() {
        isActive = false
        keys = []
    }
}
