import CoreGraphics

/// Where a file dropped on the panel lands.
enum ArchiveDropZone: Equatable, CaseIterable {
    /// Straight out to another device — the files are not kept.
    case airDrop
    /// The archive's own shelf of dropped files.
    case archive
    /// Keep the files in the archive, then open one of them in the editor.
    case editor

    /// SF Symbol used by the corresponding drop plate.
    var icon: String {
        switch self {
        case .airDrop: return "airplayaudio"
        case .archive: return "arrow.down.document.fill"
        case .editor: return "square.and.pencil"
        }
    }
}

/// Geometry of the ordered drop band.
///
/// The table is deliberately the single source of truth for both plate order
/// and their relative widths. The band is as wide as the screen's notch area,
/// so storing fractions instead of points keeps the targets usable across
/// displays and panel styles.
struct ArchiveDropLayout: Equatable {
    struct Plate: Equatable {
        let zone: ArchiveDropZone
        let fraction: CGFloat
    }

    /// The order and proportions chosen for the first editor drop affordance.
    /// The archive remains the safe, widest target in the middle.
    static let defaultPlates: [Plate] = [
        Plate(zone: .airDrop, fraction: 0.20),
        Plate(zone: .archive, fraction: 0.60),
        Plate(zone: .editor, fraction: 0.20)
    ]

    /// Full width of the view the drop lands on (the panel).
    let totalWidth: CGFloat
    /// Distance from the panel edge to the plates — the panel's shoulder plus
    /// the plate's own gap.
    let sideInset: CGFloat
    /// Space between adjacent plates.
    let gap: CGFloat
    /// Ordered plates. Changing the layout means editing this table, not the
    /// hit-testing arithmetic or the view's geometry.
    let plates: [Plate]

    init(totalWidth: CGFloat,
         sideInset: CGFloat,
         gap: CGFloat = 6,
         plates: [Plate] = ArchiveDropLayout.defaultPlates) {
        self.totalWidth = totalWidth
        self.sideInset = sideInset
        self.gap = max(0, gap)
        self.plates = plates
    }

    /// Width available to the plates, excluding the gaps between them.
    private var usablePlateWidth: CGFloat {
        max(0, bandWidth - gap * CGFloat(max(0, plates.count - 1)))
    }

    /// Width available to all plates together, gaps included.
    var bandWidth: CGFloat { max(0, totalWidth - sideInset * 2) }

    /// Width for each plate in table order. The final plate receives the
    /// remainder so rounding never leaves an unaccounted-for sliver.
    var plateWidths: [CGFloat] {
        guard !plates.isEmpty else { return [] }

        let fractions = plates.map { max(0, $0.fraction) }
        let fractionTotal = fractions.reduce(0, +)
        let effectiveFractions: [CGFloat]
        if fractionTotal > 0 {
            effectiveFractions = fractions.map { $0 / fractionTotal }
        } else {
            let equalFraction = 1 / CGFloat(plates.count)
            effectiveFractions = Array(repeating: equalFraction, count: plates.count)
        }

        var consumed: CGFloat = 0
        return effectiveFractions.enumerated().map { index, fraction in
            if index == effectiveFractions.count - 1 {
                return max(0, usablePlateWidth - consumed)
            }
            let width = usablePlateWidth * fraction
            consumed += width
            return max(0, width)
        }
    }

    /// Zone for a drop at `x` in the panel's coordinate space. Everything
    /// outside the band — the shoulders — resolves to the archive: those are
    /// pixels the user can hit by accident, and the safe outcome is keeping the
    /// files.
    func zone(atX x: CGFloat) -> ArchiveDropZone {
        guard !plates.isEmpty,
              bandWidth > 0,
              x >= sideInset,
              x <= sideInset + bandWidth
        else { return .archive }

        var plateStart = sideInset
        let widths = plateWidths
        for index in plates.indices {
            let plateEnd = plateStart + widths[index]
            let isLast = index == plates.count - 1
            if isLast || x < plateEnd + gap / 2 {
                return plates[index].zone
            }
            plateStart = plateEnd + gap
        }

        return .archive
    }
}
