/// Layers moving at different speeds cannot measure a page step, but their
/// edges can still prefer the distance already confirmed by ordinary steps.
nonisolated enum ScrollParallax {
    static func canInspect(axis: ScrollAxis, calibrationConfirmed: Bool, cleanStep: Bool,
                           isPush: Bool, expected: Int?, frameChanged: Bool) -> Bool {
        axis == .vertical && calibrationConfirmed && cleanStep && !isPush
            && expected != nil && frameChanged
    }

    static func shouldLay(axis: ScrollAxis, calibrationConfirmed: Bool, cleanStep: Bool,
                          isPush: Bool, expected: Int?, frameChanged: Bool,
                          pair: ScrollQueueLaying.PairCost?) -> Bool {
        guard canInspect(axis: axis, calibrationConfirmed: calibrationConfirmed, cleanStep: cleanStep,
                         isPush: isPush, expected: expected, frameChanged: frameChanged),
              let pair, !pair.identical else { return false }
        return pair.shifted < ScrollQueueLaying.shiftedShare * pair.still
    }
}
