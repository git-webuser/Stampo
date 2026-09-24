import AppKit
import SwiftUI

/// A native segmented control whose segments share one width, whatever they
/// hold.
///
/// SwiftUI's segmented `Picker` sizes its segments by their content: a text
/// segment stretched to the width it was given, an image segment kept to its
/// glyph and sat centred in the rest, so the settings row's pickers came out
/// in as many widths as they had kinds of label. Every choice in the row is
/// built here instead, from a symbol or a short piece of text.
///
/// The control's width is set as a whole and the segments split it evenly
/// (`fillEqually`): a per-segment width left the control's total to AppKit,
/// which adds its own borders and separators — two segments and three came
/// out at different, unpredictable totals.
struct UniformSegmentedPicker<Value: Equatable>: NSViewRepresentable {
    /// The one width of every picker in the settings row, two segments or
    /// three.
    static var rowWidth: CGFloat { 108 }

    enum Width {
        /// This many points, whatever the room around it.
        case fixed(CGFloat)
        /// The whole width it is offered — a block-wide switch in the
        /// inspector.
        case fill
    }

    struct Segment {
        enum Content {
            case symbol(String)
            case text(String)
        }

        let content: Content
        let value: Value

        static func symbol(_ name: String, _ value: Value) -> Segment {
            Segment(content: .symbol(name), value: value)
        }

        static func text(_ text: String, _ value: Value) -> Segment {
            Segment(content: .text(text), value: value)
        }
    }

    let segments: [Segment]
    @Binding var selection: Value
    var width: Width = .fixed(Self.rowWidth)
    var controlSize: NSControl.ControlSize = .regular

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.controlSize = controlSize
        control.segmentCount = segments.count
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectionChanged(_:))
        for (index, segment) in segments.enumerated() {
            switch segment.content {
            case .symbol(let name):
                control.setImage(NSImage(systemSymbolName: name, accessibilityDescription: nil),
                                 forSegment: index)
                control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            case .text(let text):
                control.setLabel(text, forSegment: index)
            }
        }
        // The width comes from `sizeThatFits`; the control must not insist on
        // its content's.
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = segments.firstIndex { $0.value == selection } ?? -1
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView control: NSSegmentedControl,
                      context: Context) -> CGSize? {
        let height = control.intrinsicContentSize.height
        switch width {
        case .fixed(let points):
            return CGSize(width: points, height: height)
        case .fill:
            // An unspecified proposal is SwiftUI asking for the ideal size:
            // the content's own width, so a fill picker still has one.
            let natural = control.intrinsicContentSize.width
            return CGSize(width: proposal.width ?? natural, height: height)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: UniformSegmentedPicker
        init(_ parent: UniformSegmentedPicker) { self.parent = parent }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            guard parent.segments.indices.contains(sender.selectedSegment) else { return }
            parent.selection = parent.segments[sender.selectedSegment].value
        }
    }
}
