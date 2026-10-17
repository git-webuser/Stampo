/// A pinned gallery spends vertical wheel steps moving cards sideways. Its
/// stages replace one frame; only a laid vertical step starts a new section.
nonisolated struct ScrollSidewaysSection {
    static let limit = 24
    private(set) var stages = 0

    static func isStage(axis: ScrollAxis, verticalUndecided: Bool, frameChanged: Bool,
                        pushMode: ScrollPush.Mode, checking: Bool, queueIsEmpty: Bool,
                        sidewaysMatched: Bool) -> Bool {
        axis == .vertical && verticalUndecided && frameChanged && pushMode == .none
            && !checking && queueIsEmpty && sidewaysMatched
    }

    mutating func replacedFrame() { stages += 1 }
    mutating func laidVerticalStep() { stages = 0 }
    var isExhausted: Bool { stages >= Self.limit }
}
