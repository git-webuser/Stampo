import AppKit
import SwiftUI

/// Native `NSSegmentedControl` with an SF Symbol next to the label in each
/// segment. SwiftUI's segmented `Picker` drops images while bridging its
/// content to AppKit (a `Label` keeps only the title, a `Text` with an
/// embedded `Image` keeps only the string), so the control is configured
/// directly — AppKit renders `setImage` + `setLabel` side by side natively.
struct IconSegmentedPicker<Value: Equatable>: NSViewRepresentable {
    struct Segment {
        let title: String
        let systemImage: String
        let value: Value

        init(_ title: String.LocalizationValue, systemImage: String, value: Value) {
            self.title = String(localized: title)
            self.systemImage = systemImage
            self.value = value
        }
    }

    let segments: [Segment]
    @Binding var selection: Value
    /// Extra horizontal room added to every segment beyond its measured
    /// content, matching the roomier feel of the glyph pickers. Applied on top
    /// of a runtime sizing pass, so it scales with localization and with any
    /// future change in the system control's own metrics.
    var segmentPadding: CGFloat = 16

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.segmentCount = segments.count
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectionChanged(_:))
        for (index, segment) in segments.enumerated() {
            control.setLabel(segment.title, forSegment: index)
            if let image = NSImage(systemSymbolName: segment.systemImage,
                                   accessibilityDescription: segment.title) {
                control.setImage(image, forSegment: index)
                control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            }
        }
        applyPaddedWidths(to: control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = segments.firstIndex { $0.value == selection } ?? -1
    }

    /// Sizes every segment to the widest auto-fit content plus `segmentPadding`.
    /// Measuring the live control (rather than hardcoding a width) keeps the
    /// picker correct across languages and across appearance changes such as
    /// macOS Tahoe's Liquid Glass, whose own segment metrics feed this pass.
    private func applyPaddedWidths(to control: NSSegmentedControl) {
        guard !segments.isEmpty else { return }
        for index in segments.indices { control.setWidth(0, forSegment: index) }
        control.sizeToFit()
        let perSegment = ceil(control.intrinsicContentSize.width
                              / CGFloat(segments.count)) + segmentPadding
        for index in segments.indices { control.setWidth(perSegment, forSegment: index) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: IconSegmentedPicker
        init(_ parent: IconSegmentedPicker) { self.parent = parent }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            guard parent.segments.indices.contains(sender.selectedSegment) else { return }
            parent.selection = parent.segments[sender.selectedSegment].value
        }
    }
}
