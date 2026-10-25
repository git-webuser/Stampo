import AppKit
import SwiftUI

/// The divider is the frame between the panel and the canvas, not a rule.
final class FrameSplitView: NSSplitView {
    override var dividerThickness: CGFloat { ArcFrameLayout.frameGap }
    override var dividerColor: NSColor { .clear }
    override func drawDivider(in rect: NSRect) {}
}

struct FrameSplit<Panel: View, Detail: View>: NSViewControllerRepresentable {
    var panel: Panel
    var detail: Detail
    @Binding var isPresented: Bool

    func makeNSViewController(context: Context) -> FrameSplitController {
        let controller = FrameSplitController(panel: AnyView(panel.managedLocale()),
                                              detail: AnyView(detail.managedLocale()),
                                              isPresented: isPresented)
        controller.presentationChanged = { [weak controller] _ in
            // KVO also fires during AppKit layout. Publish after that pass,
            // and read the final value so a queued collapse cannot undo a click.
            DispatchQueue.main.async { [weak controller] in
                guard let controller, !controller.animatingPresentation else { return }
                let presented = !controller.panelItem.isCollapsed
                if isPresented != presented { isPresented = presented }
            }
        }
        return controller
    }

    func updateNSViewController(_ controller: FrameSplitController, context: Context) {
        controller.panelHosting.rootView = AnyView(panel.managedLocale())
        controller.detailHosting.rootView = AnyView(detail.managedLocale())
        controller.setPresented(isPresented)
    }

    static func dismantleNSViewController(_ controller: FrameSplitController, coordinator: ()) {
        controller.presentationChanged = nil
    }
}

final class FrameSplitController: NSSplitViewController {
    let panelHosting: NSHostingController<AnyView>
    let detailHosting: NSHostingController<AnyView>
    let panelItem: NSSplitViewItem
    var presentationChanged: ((Bool) -> Void)?
    private var collapseObservation: NSKeyValueObservation?
    private var positionedPanel = false
    private var panelPositionScheduled = false
    private var requestedPresentation: Bool
    private var presentationRevision = 0
    private(set) var animatingPresentation = false

    init(panel: AnyView, detail: AnyView, isPresented: Bool) {
        requestedPresentation = isPresented
        panelHosting = NSHostingController(rootView: panel)
        detailHosting = NSHostingController(rootView: detail)
        panelHosting.sizingOptions = []
        detailHosting.sizingOptions = []
        panelItem = NSSplitViewItem(viewController: panelHosting)
        super.init(nibName: nil, bundle: nil)

        splitView = FrameSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        panelItem.minimumThickness = EditorView.arcPanelMinimumWidth
        panelItem.maximumThickness = EditorView.arcPanelMaximumWidth
        panelItem.canCollapse = true
        panelItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        // Preserve the panel on window resize, but let a divider drag (490)
        // override its held width. A defaultHigh priority prevents dragging.
        panelItem.holdingPriority = NSLayoutConstraint.Priority(260)
        panelItem.isCollapsed = !isPresented
        let detailItem = NSSplitViewItem(viewController: detailHosting)
        detailItem.minimumThickness = EditorView.arcDetailMinimumWidth
        detailItem.holdingPriority = .defaultLow
        addSplitViewItem(panelItem)
        addSplitViewItem(detailItem)
        collapseObservation = panelItem.observe(\.isCollapsed) { [weak self] _, _ in
            // AppKit changes split items on the main thread.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.presentationChanged?(!self.panelItem.isCollapsed)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPresented(_ presented: Bool) {
        // A native collapse reaches the binding after layout. Until then an
        // unrelated SwiftUI update still carries the previous request; it
        // must not reopen the item before the observed state is published.
        guard presented != requestedPresentation else { return }
        requestedPresentation = presented
        presentationRevision += 1
        let revision = presentationRevision
        if panelItem.isCollapsed == presented {
            animatingPresentation = true
            // AppKit's collapse lays out its hosts synchronously. Leave the
            // representable's SwiftUI update before starting that layout.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.presentationRevision == revision else { return }
                NSAnimationContext.runAnimationGroup { _ in
                    self.panelItem.animator().isCollapsed = !presented
                } completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.presentationRevision == revision else { return }
                        self.animatingPresentation = false
                        self.scheduleInitialPanelPosition()
                        self.presentationChanged?(!self.panelItem.isCollapsed)
                    }
                }
            }
        } else {
            animatingPresentation = false
            scheduleInitialPanelPosition()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        scheduleInitialPanelPosition()
    }

    private func scheduleInitialPanelPosition() {
        guard !positionedPanel, !panelPositionScheduled, !panelItem.isCollapsed,
              !animatingPresentation, splitView.bounds.width > 0 else { return }
        // A collapsed item is loaded lazily. Position its first visible layout,
        // otherwise NSSplitView opens it at maximumThickness.
        panelPositionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panelPositionScheduled = false
            guard !self.panelItem.isCollapsed, !self.animatingPresentation else { return }
            self.positionedPanel = true
            self.splitView.setPosition(EditorView.arcPanelDefaultWidth, ofDividerAt: 0)
        }
    }
}
