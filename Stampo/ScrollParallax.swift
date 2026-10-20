/// Layers moving at different speeds cannot measure a page step, but their
/// edges can still prefer the distance already confirmed by ordinary steps.
nonisolated enum ScrollParallax {
    static func canInspect(axis: ScrollAxis, calibrationConfirmed: Bool, cleanStep: Bool,
                           isPush: Bool, expected: Int?, frameChanged: Bool) -> Bool {
        axis == .vertical && calibrationConfirmed && cleanStep && !isPush
            && expected != nil && frameChanged
    }

    /// The 0.8 margin is narrow on lenis: 181958/12 = 0.74, 184202/12 = 0.76
    /// (2026-10-17), 2026-10-16-211712/12 = 0.75. In the 2026-10-11 corpus,
    /// 115436/43 is refused at 0.888; claude.com 143535/24, 143834/25 and
    /// 193039/05 pass comfortably at 0.14–0.15. Do not relax this for a backdrop.
    static func shouldLay(axis: ScrollAxis, calibrationConfirmed: Bool, cleanStep: Bool,
                          isPush: Bool, expected: Int?, frameChanged: Bool,
                          pair: ScrollQueueLaying.PairCost?) -> Bool {
        guard canInspect(axis: axis, calibrationConfirmed: calibrationConfirmed, cleanStep: cleanStep,
                         isPush: isPush, expected: expected, frameChanged: frameChanged),
              let pair, !pair.identical else { return false }
        return pair.shifted < ScrollQueueLaying.shiftedShare * pair.still
    }
}
