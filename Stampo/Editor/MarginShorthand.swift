import CoreGraphics
import Foundation

/// Margins written the way stylesheets write them.
///
/// The panel shows the four margins as two fields — one per axis — and each has
/// to answer an awkward question: what does it say when the two sides it stands
/// for are not equal? A single number would be a lie, and a dash says nothing.
/// A list says both: `10 84` is a top of 10 and a bottom of 84, and typing that
/// back sets exactly those.
///
/// Once a field reads a list, it may as well read the whole shorthand — one
/// number for all four, two for the axes, three for top / sides / bottom, four
/// going round from the top. That is a notation the people who take screenshots
/// of code already know, and it costs one function.
nonisolated enum MarginShorthand {
    /// Which margins a field stands for.
    enum Target: Equatable, Sendable {
        case side(PresentationLayout.Edge)
        case vertical
        case horizontal
    }

    /// The numbers in a piece of text, in the order they were written.
    ///
    /// Space and comma both separate. Margins are whole pixels — the panel
    /// rounds them everywhere — so a comma here is a separator and never a
    /// decimal point, which is the one place this differs from the other
    /// number fields.
    static func numbers(in text: String) -> [CGFloat] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isLetter }) else { return [] }
        return trimmed
            .split(whereSeparator: { " ,;/".contains($0) })
            .compactMap { piece -> CGFloat? in
                guard let value = Double(piece), value.isFinite else { return nil }
                return CGFloat(value.rounded())
            }
    }

    /// The margins a typed list makes, starting from the ones already set.
    ///
    /// One and two numbers mean whatever the field itself stands for — the
    /// side, or the axis it names. Three and four are the stylesheet's own
    /// meaning and reach every side, whichever field they were typed into: a
    /// person who writes four numbers has said what they want about all four.
    static func applied(_ values: [CGFloat], from target: Target,
                        to margins: Presentation.Margins) -> Presentation.Margins {
        var result = margins
        switch (values.count, target) {
        case (0, _):
            return margins

        case (1, .side(let edge)):
            result[edge] = values[0]

        case (1, .vertical):
            result.top = values[0]
            result.bottom = values[0]

        case (1, .horizontal):
            result.leading = values[0]
            result.trailing = values[0]

        case (2, .vertical):
            result.top = values[0]
            result.bottom = values[1]

        case (2, .horizontal):
            result.leading = values[0]
            result.trailing = values[1]

        case (2, .side):
            // A side field given two numbers is reading the stylesheet's pair:
            // vertical, then horizontal.
            result = Presentation.Margins(top: values[0], leading: values[1],
                                          bottom: values[0], trailing: values[1])

        case (3, _):
            result = Presentation.Margins(top: values[0], leading: values[1],
                                          bottom: values[2], trailing: values[1])

        default:
            // Four or more: top, right, bottom, left, going round from the top,
            // and anything past the fourth is not a margin.
            result = Presentation.Margins(top: values[0], leading: values[3],
                                          bottom: values[2], trailing: values[1])
        }
        return result
    }

    /// What a field shows: one number while the sides it stands for agree, and
    /// the list when they do not.
    static func text(for target: Target, of margins: Presentation.Margins) -> String {
        func write(_ values: [CGFloat]) -> String {
            values.map { String(Int($0.rounded())) }.joined(separator: " ")
        }
        switch target {
        case .side(let edge):
            return write([margins[edge]])
        case .vertical:
            return write(margins.top == margins.bottom
                         ? [margins.top] : [margins.top, margins.bottom])
        case .horizontal:
            return write(margins.leading == margins.trailing
                         ? [margins.leading] : [margins.leading, margins.trailing])
        }
    }

    /// The values behind that text, for a field that edits numbers rather than
    /// a string.
    static func values(for target: Target, of margins: Presentation.Margins) -> [CGFloat] {
        numbers(in: text(for: target, of: margins))
    }
}
