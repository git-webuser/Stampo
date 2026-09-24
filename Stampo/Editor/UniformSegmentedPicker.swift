import AppKit
import SwiftUI

/// A native segmented control whose segments are all one width, whatever they
/// hold.
///
/// SwiftUI's segmented `Picker` sizes its segments by their content: a text
/// segment stretched to the width it was given, an image segment kept to its
/// glyph and sat centred in the rest, so the settings row's pickers came out
/// in as many widths as they had kinds of label. Every choice in the row is
/// built here instead, from a symbol or a short piece of text, on one width.
struct UniformSegmentedPicker<Value: Equatable>: NSViewRepresentable {
    /// The one width of every segment in the settings row.
    static var segmentWidth: CGFloat { 36 }

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

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
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
            control.setWidth(Self.segmentWidth, forSegment: index)
        }
        control.setContentHuggingPriority(.required, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = segments.firstIndex { $0.value == selection } ?? -1
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
