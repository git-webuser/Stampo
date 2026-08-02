import CoreGraphics

/// Where a file dropped on the panel lands.
enum ArchiveDropZone: Equatable {
    /// Straight out to another device — the files are not kept.
    case airDrop
    /// The archive's own shelf of dropped files.
    case archive
}

/// Geometry of the split drop band: a narrow AirDrop plate on the leading side,
/// the archive plate taking the rest.
///
/// AirDrop gets the smaller half on purpose. Dropping into the archive is the
/// everyday gesture and AirDrop the deliberate one, so a hand that lands
/// roughly in the middle should keep the files rather than open a send sheet.
/// The split is a fraction rather than a fixed width because the panel is as
/// wide as the screen's notch band, which varies by display and by style.
struct ArchiveDropLayout: Equatable {
    /// Full width of the view the drop lands on (the panel).
    let totalWidth: CGFloat
    /// Distance from the panel edge to the plates — the panel's shoulder plus
    /// the plate's own gap.
    let sideInset: CGFloat
    /// Space between the two plates.
    let gap: CGFloat
    /// Share of the usable band given to AirDrop.
    let airDropFraction: CGFloat

    init(totalWidth: CGFloat,
         sideInset: CGFloat,
         gap: CGFloat = 6,
         airDropFraction: CGFloat = 0.28) {
        self.totalWidth = totalWidth
        self.sideInset = sideInset
        self.gap = gap
        self.airDropFraction = airDropFraction
    }

    /// Width available to both plates together, gap included.
    var bandWidth: CGFloat { max(0, totalWidth - sideInset * 2) }

    var airDropWidth: CGFloat { max(0, (bandWidth - gap) * airDropFraction) }

    var archiveWidth: CGFloat { max(0, bandWidth - gap - airDropWidth) }

    /// The boundary sits in the middle of the gap, so neither plate claims
    /// pixels the user sees as empty space.
    var boundaryX: CGFloat { sideInset + airDropWidth + gap / 2 }

    /// Zone for a drop at `x` in the panel's coordinate space. Everything
    /// outside the band — the shoulders — resolves to the archive: those are
    /// pixels the user can hit by accident, and the safe outcome is keeping the
    /// files.
    func zone(atX x: CGFloat) -> ArchiveDropZone {
        guard airDropWidth > 0, x >= sideInset else { return .archive }
        return x < boundaryX ? .airDrop : .archive
    }
}
