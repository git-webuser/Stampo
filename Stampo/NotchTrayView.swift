import SwiftUI
import AppKit
import UniformTypeIdentifiers


// MARK: - NotchTrayView

struct NotchTrayView: View {
    let metrics: NotchMetrics
    var trayModel: NotchTrayModel
    let isPinned: Bool
    /// True while the tray content is on screen; flips to false as the tray
    /// closes (back, hide, ESC). Drives the ephemeral collapse of any expanded
    /// stack so the tray always reopens fully collapsed.
    let isContentVisible: Bool
    let onBack: () -> Void
    let onHidePanel: () -> Void
    let onTogglePin: () -> Void

    @AppStorage(AppSettings.Keys.defaultColorFormat) private var scheme: ColorSchemeType = .hex
    /// Cell currently hovered via a TrayDragShim NSView (screenshot or stack
    /// cells — the AppKit shim owns hover tracking for drag-capable cells).
    @State private var hoveredDragCellID: UUID?
    @State private var isDropTargeted = false
    /// True while any tray cell is mid drag-out (its TrayDragShim reports through
    /// `InternalDraggingKey`). SwiftUI's `.onDrop` also fires `isDropTargeted`
    /// for the app's OWN drags, so this gates them out: without it, dragging a
    /// screenshot back over the tray re-ingests it as a duplicate stack, and the
    /// drop plate paints over the content being dragged.
    @State private var isInternalDragging = false
    /// Which stack is currently expanded into an inline accordion, if any.
    /// Ephemeral: never persisted, reset when the tray leaves the stage or the
    /// stack disappears (see `effectiveExpandedID`).
    @State private var expandedStackID: UUID?

    /// Inline expansion is a quick peek, not a file browser: cap how many
    /// members render in the row; the overflow tail routes the rest to Finder.
    private let memberCap = 60

    /// `expandedStackID`, but only if that stack still exists in the tray.
    /// A stack can vanish while expanded (last member removed → model drops it,
    /// `trim()`, or Remove from the menu); this guard collapses the view instead
    /// of rendering an accordion for a stack that is no longer there.
    private var effectiveExpandedID: UUID? {
        guard let id = expandedStackID,
              trayModel.items.contains(where: { $0.id == id })
        else { return nil }
        return id
    }

    private func handleBack() {
        onBack()  // controller drives the content fade-out
    }

    // Real notch has a large corner radius and wide flared shape, so it needs
    // generous horizontal clearance; notch-less shapes are small/straight, so
    // the side insets (and the soft fade) are tighter. Vertical paddings are
    // unchanged. scrollPadH (header) stays aligned with the scroll content's
    // first cell (innerInset + contentInset).
    private var panelRounding: CGFloat { metrics.hasNotch ? 19 : 10 }  // clearance for panel corner radius
    private var innerInset:    CGFloat { metrics.hasNotch ? 15 : 8 }   // scroll container inset from panel edge
    private var contentInset:  CGFloat { metrics.hasNotch ? 18 : 10 }  // leading/trailing padding (and fade width) inside scroll content
    private var scrollPadH:    CGFloat { panelRounding + innerInset }
    /// The notch tab tapers inward at the bottom shoulders (NotchTabShape: wall
    /// at x=15, bottom edge at x=31 → a 16pt skew). Without this the tray
    /// content — which reaches down into the shoulder band — spills past the
    /// shape by exactly the skew, so inset the whole layout (header + scroll
    /// stay aligned) by that amount. Rounded style has straight sides → 0.
    private var skewInset: CGFloat { metrics.pinnedToTopEdge ? 16 : 0 }
    private let cellSpacing:   CGFloat = 8
    private let cellH:         CGFloat = 32
    private let badgeBleed:    CGFloat = 3
    private let labelOffset:   CGFloat = 18

    var scrollRowHeight: CGFloat { 55 }
    var trayHeight:      CGFloat { metrics.panelHeight + scrollRowHeight }

    var body: some View {
        Group {
            if metrics.hasNotch {
                notchLayout
            } else {
                noNotchLayout
            }
        }
        .frame(height: trayHeight)
        // Overlay (not background) so the plate rides ABOVE the cells: its
        // icon+label stay visible and it fully covers an expanded stack while
        // targeting. `allowsHitTesting(false)` keeps the drop landing on the row.
        .overlay { dropHighlight }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        // Ephemeral expansion: collapse whenever the tray closes so it always
        // reopens in the compact grid.
        .onChange(of: isContentVisible) {
            if !isContentVisible { expandedStackID = nil }
        }
        // Clear the stored id once its stack is gone (last member removed, trim,
        // Remove) — effectiveExpandedID already masks the render; this dedupes
        // the latent @State so it can never point at a dead stack.
        .onChange(of: effectiveExpandedID) {
            if effectiveExpandedID == nil { expandedStackID = nil }
        }
        // Aggregate drag state from every TrayDragShim-backed cell below.
        .onPreferenceChange(InternalDraggingKey.self) { isInternalDragging = $0 }
    }

    /// Drop frame (user-designed mock, "Frame 1000001163"): not a contour
    /// ring but a filled plate marking the shelf band — top edge exactly at
    /// the header boundary (panelHeight), 20pt side insets, 5pt off the
    /// bottom, radii 9.6 top / 17.6 bottom, dashed system-blue outline.
    /// Rendered as the view's background so cells ride on top of it.
    private var dropHighlight: some View {
        // Geometry adapts to the panel style:
        // - shoulder styles (real notch, notch tab): side inset = wall(15) +
        //   5pt gap; bottom radius 11 = the 16pt shoulder arc minus the gap
        //   (concentric), top radius = buttonRadius to match the controls.
        // - rounded style: straight sides at x=0, so a uniform 5pt gap all
        //   around and buttonRadius corners everywhere.
        let hasShoulders = metrics.hasNotch || metrics.pinnedToTopEdge
        let pad: CGFloat = 5
        let sideInset: CGFloat = hasShoulders ? 15 + pad : pad
        let topRadius = metrics.buttonRadius
        let bottomRadius: CGFloat = hasShoulders ? 16 - pad : metrics.buttonRadius
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: topRadius,
            style: .continuous
        )
        return shape
            .fill(Color(red: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255))
            .overlay(
                shape.stroke(
                    Color(red: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [4, 4])
                )
            )
            .overlay {
                // The plate's own state hint. Now that the plate is an overlay
                // riding above the cells, it covers the whole shelf band while
                // targeting, so the hint shows for every external drop — not only
                // the empty tray. (The plate itself is opacity-gated on
                // isDropTargeted, so this is only visible mid-drop.)
                trayHint(icon: "tray.and.arrow.down.fill", label: "Drop Files Here")
            }
            .padding(.top, metrics.panelHeight)
            .padding(.horizontal, sideInset)
            .padding(.bottom, pad)
            // Only for EXTERNAL drags — an internal drag-out must not paint the
            // plate over the very cells being moved.
            .opacity((isDropTargeted && !isInternalDragging) ? 1 : 0)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // Ignore the app's own drags: a tray cell dropped back onto the tray
        // would otherwise be re-ingested (e.g. a screenshot becomes a duplicate
        // stack). External file drops leave isInternalDragging false.
        guard !isInternalDragging else { return false }
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        // loadObject completions race, so write each result into its own slot
        // keyed by provider index — the drop's order is then preserved (fan
        // order, and which folder-stack lands in front) instead of depending
        // on which loads happen to finish first. The lock guards the array
        // itself (concurrent Swift-array writes race even at disjoint indices).
        let group = DispatchGroup()
        let lock = NSLock()
        var slots = [URL?](repeating: nil, count: fileProviders.count)
        for (index, provider) in fileProviders.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock()
                    slots[index] = url
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = slots.compactMap { $0 }
            guard !urls.isEmpty else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                trayModel.add(droppedFiles: urls)
                // Collapse on a landed drop: show the (possibly reordered) stack
                // in its compact form. This also sidesteps the reorder jank —
                // add() moves a touched stack to the front, and an expanded group
                // jumping across the row would read as broken.
                expandedStackID = nil
            }
        }
        return true
    }

    private var notchLayout: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let shoulders  = (totalWidth - metrics.notchGap) / 2

            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        HStack(spacing: metrics.gap) {
                            backButton
                            schemeMenu
                        }
                        .padding(.leading, metrics.edgeSafe)
                        .frame(width: shoulders, alignment: .leading)

                        Color.clear.frame(width: metrics.notchGap)

                        HStack(spacing: metrics.gap) {
                            pinButton
                            moreButton
                        }
                        .padding(.trailing, metrics.edgeSafe)
                        .frame(width: shoulders, alignment: .trailing)
                    }
                    .frame(height: metrics.panelHeight)

                    if !trayModel.items.isEmpty {
                        scrollContent.frame(height: scrollRowHeight)
                    }
                }

                // Empty state spans full trayHeight → centers relative to whole panel
                if trayModel.items.isEmpty {
                    emptyState.frame(height: trayHeight)
                }
            }
        }
    }

    private var noNotchLayout: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                HStack(spacing: metrics.gap) {
                    backButton
                    schemeMenu
                    if metrics.pinnedToTopEdge {
                        // Notch style has no notch pill to tap, so let the empty
                        // centre of the header dismiss the panel — the same
                        // tap-to-close gesture the notch pill provides on a real
                        // notch. (Buttons sit on the shoulders and keep their taps.)
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { onHidePanel() }
                    } else {
                        Spacer()
                    }
                    pinButton
                    moreButton
                }
                .padding(.horizontal, scrollPadH)
                .frame(height: metrics.panelHeight)

                if !trayModel.items.isEmpty {
                    scrollContent.frame(height: scrollRowHeight)
                }
            }

            // Empty state spans full trayHeight → centers relative to whole panel
            if trayModel.items.isEmpty {
                emptyState.frame(height: trayHeight)
            }
        }
        // Keep content inside the notch tab's tapering shoulders.
        .padding(.horizontal, skewInset)
    }

    /// Shared vertical "icon over label" hint, used both for the resting empty
    /// tray and for the drop plate's targeting hint so the two read as one
    /// visual language.
    private func trayHint(icon: String, label: LocalizedStringKey) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private var emptyState: some View {
        trayHint(icon: "photo.on.rectangle.angled", label: "Nothing Here Yet")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        // The drop plate carries its own hint while a drag hovers — showing
        // both indicators at once reads as overlapping clutter.
        .opacity(isDropTargeted ? 0 : 1)
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
    }

    private var scrollContent: some View {
        ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: cellSpacing) {
                ForEach(trayModel.items) { item in
                    Group {
                        switch item {
                        case .screenshot(let shot):
                            TrayScreenshotCell(
                                shot: shot,
                                loader: trayModel.thumbnailLoader(for: shot),
                                height: cellH,
                                badgeBleed: badgeBleed,
                                labelOffset: labelOffset,
                                cornerRadius: metrics.buttonRadius,
                                isHovered: hoveredDragCellID == shot.id,
                                setHovered: { hovering in
                                    if hovering {
                                        hoveredDragCellID = shot.id
                                    } else if hoveredDragCellID == shot.id {
                                        hoveredDragCellID = nil
                                    }
                                },
                                onOpen: { onHidePanel() },
                                onRemove: {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        trayModel.remove(id: shot.id)
                                    }
                                },
                                onMoveToTrash: {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        trayModel.remove(id: shot.id)
                                    }
                                    NSWorkspace.shared.recycle([shot.url])
                                }
                            )
                        case .color(let c):
                            TrayColorCell(
                                item: c,
                                scheme: scheme,
                                height: cellH,
                                badgeBleed: badgeBleed,
                                labelOffset: labelOffset,
                                cornerRadius: metrics.buttonRadius,
                                onRemove: {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        trayModel.remove(id: c.id)
                                    }
                                }
                            )
                        case .text(let t):
                            TrayTextCell(
                                item: t,
                                height: cellH,
                                badgeBleed: badgeBleed,
                                labelOffset: labelOffset,
                                cornerRadius: metrics.buttonRadius,
                                onRemove: {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        trayModel.remove(id: t.id)
                                    }
                                }
                            )
                        case .stack(let stack):
                            if stack.id == effectiveExpandedID {
                                ExpandedStackGroup(
                                    stack: stack,
                                    trayModel: trayModel,
                                    height: cellH,
                                    cornerRadius: metrics.buttonRadius,
                                    badgeBleed: badgeBleed,
                                    labelOffset: labelOffset,
                                    spacing: cellSpacing,
                                    memberCap: memberCap,
                                    onCollapse: { collapseStack() },
                                    onOpenMember: { onHidePanel() },
                                    onRevealAll: {
                                        NSWorkspace.shared.activateFileViewerSelecting(stack.urls)
                                    },
                                    onRemoveStack: {
                                        withAnimation(.easeInOut(duration: 0.18)) {
                                            trayModel.remove(id: stack.id)
                                        }
                                    }
                                )
                            } else {
                                TrayStackCell(
                                    stack: stack,
                                    loaders: stack.urls.prefix(3).map { trayModel.stackThumbnailLoader(for: $0) },
                                    height: cellH,
                                    badgeBleed: badgeBleed,
                                    labelOffset: labelOffset,
                                    cornerRadius: metrics.buttonRadius,
                                    isHovered: hoveredDragCellID == stack.id,
                                    setHovered: { hovering in
                                        if hovering {
                                            hoveredDragCellID = stack.id
                                        } else if hoveredDragCellID == stack.id {
                                            hoveredDragCellID = nil
                                        }
                                    },
                                    onExpand: { expandStack(stack.id, proxy: proxy) },
                                    onDragOutCompleted: {
                                        withAnimation(.easeInOut(duration: 0.18)) {
                                            trayModel.remove(id: stack.id)
                                        }
                                    },
                                    onRemove: {
                                        withAnimation(.easeInOut(duration: 0.18)) {
                                            trayModel.remove(id: stack.id)
                                        }
                                    }
                                )
                            }
                        }
                    }
                    // Cell exit: shrink + fade out together; neighbours
                    // slide into the gap because the surrounding HStack
                    // re-layouts inside the same withAnimation block.
                    .transition(
                        .scale(scale: 0.6, anchor: .center)
                        .combined(with: .opacity)
                    )
                }
            }
            .padding(.horizontal, contentInset)
            .padding(.top, badgeBleed)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // Fade the scroll edges with an alpha mask (reveals the panel behind —
        // never paints anything, so it can't spill outside the panel shape or
        // look like animating "fangs" the way an opaque overlay scrim did). A
        // single continuous gradient with stops — rather than three framed
        // pieces — avoids the 1–2pt sub-pixel seam under the panel scaleEffect.
        .mask(
            GeometryReader { geo in
                let f = min(0.5, contentInset / max(geo.size.width, 1))
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: f),
                        .init(color: .black, location: 1 - f),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        )
        .padding(.horizontal, innerInset)
        }
    }

    /// Expand a stack into its inline accordion and bring its header to the left
    /// edge so the user sees what they opened even if the stack sat far right.
    private func expandStack(_ id: UUID, proxy: ScrollViewProxy) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            expandedStackID = id
        }
        // Scroll after the layout swap to the expanded group has a frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                proxy.scrollTo(id, anchor: .leading)
            }
        }
    }

    private func collapseStack() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            expandedStackID = nil
        }
    }

    // MARK: - Buttons

    private var backButton: some View {
        PanelIconButton(systemName: "chevron.left", size: 14, weight: .semibold, action: handleBack)
            .frame(width: metrics.cellWidth, height: metrics.iconSize)
            .help("Back to panel")
            .accessibilityLabel("Back to panel")
    }

    private var pinButton: some View {
        PanelIconButton(
            systemName: isPinned ? "pin.fill" : "pin",
            size: 14,
            weight: .semibold,
            isActive: isPinned,
            imageOffset: 1,
            action: onTogglePin
        )
        .frame(width: metrics.cellWidth, height: metrics.iconSize)
        .help(isPinned ? "Unpin panel" : "Pin panel")
        .accessibilityLabel(isPinned ? "Unpin panel" : "Pin panel")
    }

    private var moreButton: some View {
        PanelMoreMenuButton(metrics: metrics)
            .frame(width: metrics.cellWidth, height: metrics.iconSize)
            .help("Settings and quit")
            .accessibilityLabel("Settings and quit")
    }

    private var schemeMenu: some View {
        TraySchemeMenuButton(scheme: $scheme, metrics: metrics)
            .help("Color format")
            .accessibilityLabel("Color format: \(scheme.title)")
    }
}

// MARK: - Delete Badge

struct TrayDeleteBadge: View {
    var systemName: String = "xmark.circle.fill"
    var isOn: Bool = false
    /// Overrides the tray-specific default labels below — reusers outside the
    /// tray (e.g. the pinned-screenshot close button) must not announce
    /// "Remove from tray".
    var accessibilityLabelOverride: LocalizedStringKey? = nil
    let action: () -> Void
    @Binding var isPressed: Bool

    var body: some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.palette)
            .foregroundStyle(
                isOn ? Color.white : Color(red: 0.125, green: 0.125, blue: 0.125),
                isOn ? Color(red: 0.25, green: 0.55, blue: 1.0) : Color(white: 0.914)
            )
            .font(.system(size: 16))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded   { _ in action() }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityLabelOverride
                ?? (systemName == "xmark.circle.fill" ? "Remove from tray" : (isOn ? "Unpin" : "Pin")))
    }
}

// MARK: - Tray Color Cell

private struct TrayColorCell: View {
    let item: TrayColor
    let scheme: ColorSchemeType
    let height: CGFloat
    let badgeBleed: CGFloat
    let labelOffset: CGFloat
    let cornerRadius: CGFloat
    let onRemove: () -> Void

    @State private var isHovered    = false
    @State private var isPressed    = false
    @State private var isCopied     = false
    @State private var isBadgeActive = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(nsColor: item.color))
            .frame(width: height, height: height)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(isHovered ? 0.35 : 0.12), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                TrayDeleteBadge(action: { onRemove() },
                                isPressed: $isBadgeActive)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .offset(x: badgeBleed, y: -badgeBleed)
            }
            .overlay(alignment: .bottom) {
                ZStack {
                    Text(scheme.convert(item.color))
                        .opacity(isCopied ? 0 : 1)
                    Text("Copied!")
                        .opacity(isCopied ? 1 : 0)
                }
                .font(.system(size: 11, weight: .regular, design: .default))
                .textCase(nil)
                .foregroundStyle(.white)
                .fixedSize()
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Capsule(style: .continuous).fill(Color.black.opacity(0.65)))
                .fixedSize()
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(false)
                .offset(y: labelOffset)
                .animation(.easeInOut(duration: 0.14), value: isCopied)
            }
            .scaleEffect(isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isHovered)
            .animation(.spring(response: 0.15, dampingFraction: 0.7), value: isPressed)
            .accessibilityLabel("Color \(scheme.convert(item.color))")
            .accessibilityHint("Tap to copy, hold to delete")
            .accessibilityAddTraits(.isButton)
            .onHover { isHovered = $0 }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isBadgeActive { isPressed = true }
                    }
                    .onEnded { _ in
                        isPressed = false
                        guard !isBadgeActive else { isBadgeActive = false; return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(scheme.convert(item.color), forType: .string)
                        withAnimation { isCopied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { isCopied = false }
                        }
                    }
            )
    }
}

// MARK: - Tray Text Cell

/// Plain text captured via OCR or Scan Code. Tap copies the full value to the
/// clipboard (mirrors TrayColorCell); the context menu offers Copy / Remove.
private struct TrayTextCell: View {
    let item: TrayText
    let height: CGFloat
    let badgeBleed: CGFloat
    let labelOffset: CGFloat
    let cornerRadius: CGFloat
    let onRemove: () -> Void

    @State private var isHovered    = false
    @State private var isPressed    = false
    @State private var isCopied     = false
    @State private var isBadgeActive = false

    private var width: CGFloat { height * 1.6 }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
        withAnimation { isCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { isCopied = false }
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(isHovered ? 0.35 : 0.12), lineWidth: 1)
                )

            // Miniature of the recognized text — enough to tell snippets apart.
            // Verbatim text keeps URL-shaped code payloads inert in the tray.
            Text(verbatim: item.text)
                .font(.system(size: 5, weight: .regular))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(5)
                .multilineTextAlignment(.leading)
                .padding(4)

            Image(systemName: "text.viewfinder")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            ZStack {
                Text(item.firstLine).opacity(isCopied ? 0 : 1)
                Text("Copied!").opacity(isCopied ? 1 : 0)
            }
            .font(.system(size: 11, weight: .regular, design: .default))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(Color.black.opacity(0.65)))
            .frame(maxWidth: width * 2)
            .fixedSize()
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(false)
            .offset(y: labelOffset)
            .animation(.easeInOut(duration: 0.14), value: isCopied)
        }
        .overlay(alignment: .topTrailing) {
            TrayDeleteBadge(action: { onRemove() },
                            isPressed: $isBadgeActive)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .offset(x: badgeBleed, y: -badgeBleed)
        }
        .contextMenu {
            Button("Copy") { copyText() }
            Divider()
            Button("Remove from tray") { onRemove() }
        }
        .scaleEffect(isPressed ? 0.88 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isHovered)
        .animation(.spring(response: 0.15, dampingFraction: 0.7), value: isPressed)
        .accessibilityLabel("Recognized text \(item.firstLine)")
        .accessibilityHint("Tap to copy, hold to delete")
        .accessibilityAddTraits(.isButton)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isBadgeActive { isPressed = true }
                }
                .onEnded { _ in
                    isPressed = false
                    guard !isBadgeActive else { isBadgeActive = false; return }
                    copyText()
                }
        )
    }
}

// MARK: - Tray Screenshot Cell

private struct TrayScreenshotCell: View {
    let shot: TrayScreenshot
    let loader: ThumbnailLoader
    let height: CGFloat
    let badgeBleed: CGFloat
    let labelOffset: CGFloat
    let cornerRadius: CGFloat
    let isHovered: Bool
    let setHovered: (Bool) -> Void
    let onOpen: () -> Void
    let onRemove: () -> Void
    let onMoveToTrash: () -> Void

    @State private var isPressed    = false
    @State private var isBadgeActive = false
    @State private var isDragging   = false
    @State private var isCopied     = false

    private var width: CGFloat { height * 1.6 }

    private var displayName: String {
        shot.url.deletingPathExtension().lastPathComponent
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(isHovered ? 0.35 : 0.12), lineWidth: 1)
                )

            if let img = loader.image {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Text(displayName)
                .font(.system(size: 11, weight: .regular, design: .default))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Capsule(style: .continuous).fill(Color.black.opacity(0.65)))
                .frame(maxWidth: width)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(false)
                .offset(y: labelOffset)
        }
        .overlay {
            if isCopied {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.55))
                    Text("Copied ✓")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.14)))
                .allowsHitTesting(false)
            }
        }
        .scaleEffect(isPressed ? 0.88 : (isDragging ? 0.92 : 1.0))
        .opacity(isDragging ? 0.45 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isHovered)
        .animation(.spring(response: 0.15, dampingFraction: 0.7), value: isPressed)
        .overlay {
            TrayDragShim(
                urls: [shot.url],
                dragImages: [loader.image],
                cellSize: CGSize(width: width, height: height),
                isPressed: $isPressed,
                isDragging: $isDragging,
                onHoverChange: setHovered,
                onTap: {
                    let cfg = NSWorkspace.OpenConfiguration()
                    cfg.activates = true
                    NSWorkspace.shared.open(shot.url, configuration: cfg)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { onOpen() }
                }
            )
        }
        // Badge is placed AFTER TrayDragShim so it sits above the NSView in z-order
        // and receives SwiftUI hit-testing before the NSView can intercept.
        .overlay(alignment: .topTrailing) {
            TrayDeleteBadge(action: { onRemove() },
                            isPressed: $isBadgeActive)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .offset(x: badgeBleed, y: -badgeBleed)
        }
        .contextMenu {
            Button("Edit") {
                EditorWindowController.shared.open(url: shot.url)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { onOpen() }
            }
            Button("Open") {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.open(shot.url, configuration: cfg)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { onOpen() }
            }
            Button("Pin to Screen") {
                PinnedScreenshotController.shared.pin(url: shot.url)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { onOpen() }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([shot.url]) }
            Button("Copy") {
                NSPasteboard.general.writeImage(at: shot.url)
                withAnimation { isCopied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { isCopied = false }
                }
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                onMoveToTrash()
            }
        }
        .preference(key: InternalDraggingKey.self, value: isDragging)
        .accessibilityLabel("Screenshot \(shot.url.deletingPathExtension().lastPathComponent)")
        .accessibilityHint("Tap to open, hold to delete")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Tray Stack Cell

/// The shelf pile: files the user dropped onto the tray. Shows a fan of up to
/// three member previews plus a count badge. Dragging the cell carries every
/// member URL in one session; a drag that lands outside the app clears the
/// stack (the shelf is transit storage, not an archive). Tap reveals all
/// members in Finder.
private struct TrayStackCell: View {
    let stack: TrayStack
    let loaders: [ThumbnailLoader?]
    let height: CGFloat
    let badgeBleed: CGFloat
    let labelOffset: CGFloat
    let cornerRadius: CGFloat
    let isHovered: Bool
    let setHovered: (Bool) -> Void
    let onExpand: () -> Void
    let onDragOutCompleted: () -> Void
    let onRemove: () -> Void

    @State private var isPressed     = false
    @State private var isBadgeActive = false
    @State private var isDragging    = false

    private var width: CGFloat { height * 1.6 }
    private var fanCount: Int { min(stack.urls.count, 3) }
    /// Source folder name for the label, or nil for the filesystem root
    /// ("/".lastPathComponent is "/", which reads as noise) so the label and
    /// VoiceOver fall back to the file count.
    private var folderName: String? {
        guard let name = stack.folder?.lastPathComponent, name != "/" else { return nil }
        return name
    }

    /// Preview for a fan slot: decoded thumbnail for images, the file icon for
    /// everything else (and while an image thumbnail is still decoding).
    private func previewImage(at index: Int) -> NSImage {
        if index < loaders.count, let img = loaders[index]?.image { return img }
        guard index < stack.urls.count else { return NSImage() }
        return NSWorkspace.shared.icon(forFile: stack.urls[index].path)
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(stack.urls)
    }

    /// Localized VoiceOver label; names the source folder when known so
    /// separate stacks are distinguishable (the count stays on the badge).
    private var accessibilityTitle: Text {
        if let folderName {
            return Text("File stack from \(folderName)")
        }
        return Text("File stack, \(stack.urls.count) files")
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(isHovered ? 0.35 : 0.12), lineWidth: 1)
                )

            // Fan of member previews, centred; reversed so slot 0 (the newest
            // member) draws on top.
            ForEach((0..<fanCount).reversed(), id: \.self) { idx in
                Image(nsImage: previewImage(at: idx))
                    .resizable()
                    .scaledToFill()
                    .frame(width: height * 0.78, height: height * 0.78)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius * 0.7, style: .continuous))
                    .rotationEffect(.degrees(Double(idx) * 8 - Double(fanCount - 1) * 4))
                    .offset(x: CGFloat(idx) * 6 - CGFloat(fanCount - 1) * 3)
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .overlay(alignment: .bottomTrailing) {
            Text(verbatim: "\(stack.urls.count)")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(Capsule(style: .continuous).fill(Color.black.opacity(0.65)))
                .padding(2)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            // Source folder name — the discriminator between stacks (each stack
            // is one folder). Falls back to the count if the folder is unknown.
            Text(verbatim: folderName ?? "\(stack.urls.count)")
                .font(.system(size: 11, weight: .regular, design: .default))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Capsule(style: .continuous).fill(Color.black.opacity(0.65)))
                .frame(maxWidth: width * 2)
                .fixedSize()
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(false)
                .offset(y: labelOffset)
        }
        .scaleEffect(isPressed ? 0.88 : (isDragging ? 0.92 : 1.0))
        .opacity(isDragging ? 0.45 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isHovered)
        .animation(.spring(response: 0.15, dampingFraction: 0.7), value: isPressed)
        .overlay {
            TrayDragShim(
                urls: stack.urls,
                dragImages: (0..<fanCount).map { previewImage(at: $0) },
                cellSize: CGSize(width: width, height: height),
                isPressed: $isPressed,
                isDragging: $isDragging,
                onHoverChange: setHovered,
                onTap: { onExpand() },
                onDragCompleted: { _ in onDragOutCompleted() }
            )
        }
        // Badge after the shim, mirroring TrayScreenshotCell's z-order note.
        .overlay(alignment: .topTrailing) {
            TrayDeleteBadge(action: { onRemove() },
                            isPressed: $isBadgeActive)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .offset(x: badgeBleed, y: -badgeBleed)
        }
        .contextMenu {
            Button("Show in Finder") { revealInFinder() }
            Divider()
            Button("Remove from tray") { onRemove() }
        }
        .preference(key: InternalDraggingKey.self, value: isDragging)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint("Tap to open the stack, drag to move all files")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Expanded Stack (inline accordion)

/// A stack expanded in place: `[divider] [header] [members…] [+N tail?] [divider]`.
/// Lives inside the tray's horizontal scroll row — the collapsed cell it replaces
/// morphs into this group and the neighbours slide aside. Only one stack is ever
/// expanded (the tray tracks a single `expandedStackID`).
private struct ExpandedStackGroup: View {
    let stack: TrayStack
    var trayModel: NotchTrayModel
    let height: CGFloat
    let cornerRadius: CGFloat
    let badgeBleed: CGFloat
    let labelOffset: CGFloat
    let spacing: CGFloat
    let memberCap: Int
    let onCollapse: () -> Void
    let onOpenMember: () -> Void
    let onRevealAll: () -> Void
    let onRemoveStack: () -> Void

    /// Source folder name, or nil for the filesystem root — mirrors
    /// TrayStackCell.folderName so the header reads the same as the badge.
    private var folderName: String? {
        guard let name = stack.folder?.lastPathComponent, name != "/" else { return nil }
        return name
    }
    private var shownURLs: [URL] { Array(stack.urls.prefix(memberCap)) }
    private var overflow: Int { max(0, stack.urls.count - memberCap) }

    var body: some View {
        // Top-aligned so members sit on the same line as the neighbouring tray
        // cells (the outer scroll HStack is also `.top`). Any element taller than
        // a cell (the divider) must not center-shift the row downward.
        HStack(alignment: .top, spacing: spacing) {
            divider
            header
            ForEach(shownURLs, id: \.self) { url in
                StackMemberCell(
                    url: url,
                    loader: trayModel.stackThumbnailLoader(for: url),
                    height: height,
                    badgeBleed: badgeBleed,
                    labelOffset: labelOffset,
                    cornerRadius: cornerRadius,
                    onOpen: onOpenMember,
                    onRemove: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            trayModel.removeStackMember(url: url)
                        }
                    }
                )
            }
            if overflow > 0 {
                OverflowTailCell(count: overflow, height: height,
                                 cornerRadius: cornerRadius, onReveal: onRevealAll)
            }
            // Explicit collapse at the row's end — reachable now that members are
            // capped, and pairs with the header's left-click collapse.
            CollapseButton(height: height, cornerRadius: cornerRadius, onCollapse: onCollapse)
            divider
        }
    }

    private var divider: some View {
        // Short hairline, vertically centred against the cell band (the outer
        // frame tops-aligns with cells, the line centres inside it).
        RoundedRectangle(cornerRadius: 0.5, style: .continuous)
            .fill(Color.white.opacity(0.18))
            .frame(width: 1, height: height * 0.6)
            .frame(height: height, alignment: .center)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: folderName ?? "\(stack.urls.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 120, alignment: .leading)
            Text("\(stack.urls.count) files")
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 6)
        .frame(height: height)
        .contentShape(Rectangle())
        // Left click collapses; right click opens the stack-level menu.
        .onTapGesture { onCollapse() }
        .contextMenu {
            Button("Show in Finder") { onRevealAll() }
            Button("Collapse") { onCollapse() }
            Divider()
            Button("Remove from tray") { onRemoveStack() }
        }
        .help("Collapse")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint("Tap to collapse")
        .accessibilityAddTraits(.isButton)
    }

    /// Reuses TrayStackCell's wording so the (already translated) catalog
    /// entries cover it too.
    private var accessibilityTitle: Text {
        if let folderName {
            return Text("File stack from \(folderName)")
        }
        return Text("File stack, \(stack.urls.count) files")
    }
}

/// One file inside an expanded stack. Cut from TrayScreenshotCell: image members
/// show their thumbnail, everything else the NSWorkspace file icon. Tap opens the
/// file and hides the panel; drag carries just this file; the badge removes it.
private struct StackMemberCell: View {
    let url: URL
    let loader: ThumbnailLoader?
    let height: CGFloat
    let badgeBleed: CGFloat
    let labelOffset: CGFloat
    let cornerRadius: CGFloat
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var isHovered     = false
    @State private var isPressed     = false
    @State private var isBadgeActive = false
    @State private var isDragging    = false
    /// The NSWorkspace file icon for non-image members, resolved once on appear
    /// so hover/press re-renders don't re-run the lookup.
    @State private var resolvedIcon: NSImage?

    private var width: CGFloat { height * 1.6 }
    private var displayName: String { url.lastPathComponent }

    /// Decoded thumbnail for images, the cached system file icon otherwise (and
    /// while a thumbnail is still decoding). Mirrors TrayStackCell.previewImage.
    private var previewImage: NSImage {
        loader?.image ?? resolvedIcon ?? NSWorkspace.shared.icon(forFile: url.path)
    }

    private func open() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open(url, configuration: cfg)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { onOpen() }
    }

    var body: some View {
        // Resolve once per render; reused by the thumbnail and the drag preview.
        let preview = previewImage
        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(isHovered ? 0.35 : 0.12), lineWidth: 1)
                )
            Image(nsImage: preview)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Text(displayName)
                .font(.system(size: 11, weight: .regular, design: .default))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Capsule(style: .continuous).fill(Color.black.opacity(0.65)))
                .frame(maxWidth: width)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(false)
                .offset(y: labelOffset)
        }
        .scaleEffect(isPressed ? 0.88 : (isDragging ? 0.92 : 1.0))
        .opacity(isDragging ? 0.45 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isHovered)
        .animation(.spring(response: 0.15, dampingFraction: 0.7), value: isPressed)
        .onAppear {
            if loader == nil, resolvedIcon == nil {
                resolvedIcon = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        .overlay {
            TrayDragShim(
                urls: [url],
                dragImages: [preview],
                cellSize: CGSize(width: width, height: height),
                isPressed: $isPressed,
                isDragging: $isDragging,
                onHoverChange: { isHovered = $0 },
                onTap: { open() },
                onDragCompleted: { _ in onRemove() }
            )
        }
        // Badge after the shim so it wins hit-testing (see TrayScreenshotCell).
        .overlay(alignment: .topTrailing) {
            TrayDeleteBadge(action: { onRemove() },
                            isPressed: $isBadgeActive)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .offset(x: badgeBleed, y: -badgeBleed)
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Remove from tray") { onRemove() }
        }
        .preference(key: InternalDraggingKey.self, value: isDragging)
        .accessibilityLabel("File \(displayName)")
        .accessibilityHint("Tap to open, drag to move")
        .accessibilityAddTraits(.isButton)
    }
}

/// The "+N" tail on a capped stack: no delete badge, so hovering swaps the count
/// for a folder-arrow glyph; a tap reveals every member in Finder.
private struct OverflowTailCell: View {
    let count: Int
    let height: CGFloat
    let cornerRadius: CGFloat
    let onReveal: () -> Void

    @State private var isHovered = false
    private var width: CGFloat { height * 1.6 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(isHovered ? 0.35 : 0.12), lineWidth: 1)
                )
            if isHovered {
                Image(systemName: "arrow.forward.folder")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
            } else {
                Text(verbatim: "+\(count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onReveal() }
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isHovered)
        .accessibilityLabel("\(count) more files")
        .accessibilityHint("Show all in Finder")
        .accessibilityAddTraits(.isButton)
    }
}

/// Explicit collapse action at the end of an expanded stack. Square (not the
/// cell's 1.6 aspect) so it reads as an action rather than a file; shares the
/// tail cell's rounded-rect + hover-stroke chrome for row consistency.
private struct CollapseButton: View {
    let height: CGFloat
    let cornerRadius: CGFloat
    let onCollapse: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(isHovered ? 0.35 : 0.12), lineWidth: 1)
                )
            Image(systemName: "arrow.down.forward.and.arrow.up.backward")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: height, height: height)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onCollapse() }
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isHovered)
        .help("Collapse")
        .accessibilityLabel("Collapse")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - PopUpSchemeButtonWrapper

private struct PopUpSchemeButtonWrapper: NSViewRepresentable {
    @Binding var selection: ColorSchemeType
    var onOpen:  () -> Void
    var onClose: () -> Void

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = PanelPopUpButton()
        button.isBordered       = false
        button.isTransparent    = true
        button.pullsDown        = true
        button.autoresizingMask = []
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.setAccessibilityLabel(String(localized: "Color format"))

        // pullsDown=true: the first item acts as the hidden button title,
        // so we add an empty placeholder to make HEX the first visible option.
        button.addItem(withTitle: "")
        for s in ColorSchemeType.allCases {
            button.addItem(withTitle: s.title)
        }

        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.menuWillOpen(_:)),
            name: NSPopUpButton.willPopUpNotification,
            object: button
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.menuDidClose(_:)),
            name: NSMenu.didEndTrackingNotification,
            object: button.menu
        )

        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        // +1 — offset for the empty placeholder at index 0 (pullsDown = true)
        let idx = (ColorSchemeType.allCases.firstIndex(of: selection) ?? 0) + 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            button.selectItem(at: idx)
        }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: PopUpSchemeButtonWrapper

        init(_ parent: PopUpSchemeButtonWrapper) { self.parent = parent }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let cases = ColorSchemeType.allCases
            // -1 — compensate for the empty placeholder at index 0 (pullsDown = true)
            let idx = sender.indexOfSelectedItem - 1
            guard idx >= 0, idx < cases.count else { return }
            DispatchQueue.main.async { self.parent.selection = cases[idx] }
        }

        @objc func menuWillOpen(_ notification: Notification) {
            DispatchQueue.main.async { self.parent.onOpen() }
        }

        @objc func menuDidClose(_ notification: Notification) {
            DispatchQueue.main.async { self.parent.onClose() }
        }
    }
}

// MARK: - TraySchemeMenuButton

private struct TraySchemeMenuButton: View {
    @Binding var scheme: ColorSchemeType
    let metrics: NotchMetrics

    @State private var isHovered  = false
    @State private var isPressed  = false
    @State private var isMenuOpen = false

    var body: some View {
        HStack(spacing: 5) {
            Text(scheme.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(labelColor)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(chevronColor)
        }
        .padding(.horizontal, 8)
        .frame(height: metrics.buttonHeight)
        .background(
            RoundedRectangle(cornerRadius: metrics.buttonRadius, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay {
            PopUpSchemeButtonWrapper(
                selection: $scheme,
                onOpen:  { isMenuOpen = true  },
                onClose: { isMenuOpen = false }
            )
        }
        .fixedSize()
        .scaleEffect(isPressed ? 0.88 : 1.0)
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: isPressed)
        .contentShape(Rectangle())
        .clipped()
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true  }
                .onEnded   { _ in isPressed = false }
        )
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.12), value: isMenuOpen)
    }

    private var labelColor: Color {
        if isMenuOpen { return .white }
        if isPressed  { return .white }
        if isHovered  { return .white }
        return .white.opacity(0.8)
    }

    private var chevronColor: Color {
        if isMenuOpen { return .white }
        if isPressed  { return .white }
        if isHovered  { return .white }
        return .white.opacity(0.8)
    }

    private var backgroundColor: Color {
        if isMenuOpen { return .white.opacity(0.22) }
        if isPressed  { return .white.opacity(0.28) }
        if isHovered  { return .white.opacity(0.16) }
        return .clear
    }
}

// MARK: - Drag Shim (NSView-based NSDraggingSource)

/// OR-reduces `isDragging` from every draggable tray cell up to NotchTrayView,
/// so the parent knows when one of its own cells is mid drag-out.
private struct InternalDraggingKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct TrayDragShim: NSViewRepresentable {
    let urls: [URL]
    let dragImages: [NSImage?]
    let cellSize: CGSize
    @Binding var isPressed: Bool
    @Binding var isDragging: Bool
    let onHoverChange: (Bool) -> Void
    let onTap: () -> Void
    /// Fired when a drag session ends outside this window with a non-empty
    /// operation (i.e. the payload actually landed somewhere external).
    var onDragCompleted: ((NSDragOperation) -> Void)? = nil

    func makeNSView(context: Context) -> TrayDragShimView {
        TrayDragShimView(isPressed: $isPressed, isDragging: $isDragging,
                         onHoverChange: onHoverChange, onTap: onTap)
    }

    func updateNSView(_ nsView: TrayDragShimView, context: Context) {
        nsView.urls = urls
        nsView.dragImages = dragImages
        nsView.cellSize = cellSize
        nsView.onHoverChange = onHoverChange
        nsView.onDragCompleted = onDragCompleted
    }
}

final class TrayDragShimView: NSView, NSDraggingSource {
    var urls: [URL] = []
    var dragImages: [NSImage?] = []
    var cellSize: CGSize = .zero
    var onDragCompleted: ((NSDragOperation) -> Void)?
    /// Size of the top-right corner to leave for the delete badge
    var badgeExcludeSize: CGFloat = 16

    @Binding var isPressed: Bool
    @Binding var isDragging: Bool
    /// Tracks whether the cursor is inside *this* cell's hover zone (incl. bleed),
    /// independent of which cell the parent has currently selected. Prevents
    /// neighbour cells with overlapping bleed zones from oscillating
    /// `hoveredScreenshotID` on every mouse-move event.
    var localIsInHoverZone: Bool = false
    var onHoverChange: (Bool) -> Void
    let onTap: () -> Void

    private var mouseDownPoint: NSPoint?

    init(isPressed: Binding<Bool>, isDragging: Binding<Bool>,
         onHoverChange: @escaping (Bool) -> Void, onTap: @escaping () -> Void) {
        self._isPressed = isPressed
        self._isDragging = isDragging
        self.onHoverChange = onHoverChange
        self.onTap = onTap
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Match SwiftUI coordinate system: origin top-left, y increases downward
    override var isFlipped: Bool { true }

    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .mouseEntered, .mouseExited, .leftMouseDragged]
            ) { [weak self] event in
                self?.updateHoverState()
                return event  // never consume — drag/click still work as before
            }
        } else {
            if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
            localIsInHoverZone = false
            DispatchQueue.main.async { self.onHoverChange(false) }
        }
    }

    deinit {
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
    }

    private func updateHoverState() {
        guard let window else { return }
        let pt = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        // Hover bleed must cover the delete badge that protrudes past the
        // cell, but no further — otherwise the bleed zone of one cell
        // reaches into a neighbour's core area (cellSpacing is 8 pt) and
        // mouse moves in the gap toggle hovered state between cells.
        // The badge view sits at offset (badgeBleed, -badgeBleed) past the
        // cell, so 3 pt of bleed is enough on the badge sides.
        // (Note: `badgeExcludeSize` (16) is the size of the badge corner
        // that's reserved for the badge itself in hitTest — separate concern.)
        let bleed: CGFloat = 3
        let hoverRect = NSRect(
            x: bounds.minX,
            y: -bleed,                        // extend upward past top edge
            width: bounds.width + bleed,      // extend rightward past right edge
            height: bounds.height + bleed
        )
        let hovering = hoverRect.contains(pt)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.localIsInHoverZone != hovering else { return }
            self.localIsInHoverZone = hovering
            self.onHoverChange(hovering)
        }
    }

    /// Exclude top-right badge corner so the delete badge can receive events
    override func hitTest(_ point: NSPoint) -> NSView? {
        if point.x >= bounds.width - badgeExcludeSize && point.y <= badgeExcludeSize {
            return nil
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        DispatchQueue.main.async { self.isPressed = true }
    }

    override func mouseUp(with event: NSEvent) {
        let start = mouseDownPoint
        mouseDownPoint = nil
        DispatchQueue.main.async {
            self.isPressed = false
            self.isDragging = false
        }
        if let start {
            let current = convert(event.locationInWindow, from: nil)
            // NSEvent.startDragDistance is not exposed to Swift; 4 pt matches
            // the AppKit internal threshold used by NSWindow drag detection.
            if hypot(current.x - start.x, current.y - start.y) < 4 { onTap() }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async {
            self.isPressed = false
            self.isDragging = true
        }
        let previewSize = NSSize(width: cellSize.width * 0.75, height: cellSize.height * 0.75)
        let items = urls.enumerated().map { idx, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            // Shallow cascade: the first few items carry previews, the rest
            // ride along without one (their payload still lands on the drop).
            let shift = CGFloat(min(idx, 2)) * 5
            let image = idx < dragImages.count ? dragImages[idx] : nil
            item.setDraggingFrame(NSRect(origin: NSPoint(x: shift, y: shift), size: previewSize),
                                  contents: image)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link] : [.move]
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // A drop back onto our own panel (e.g. the stack dragged an inch and
        // released over the tray) must not count as a completed drag-out.
        let insideOwnWindow = window?.frame.contains(screenPoint) == true
        DispatchQueue.main.async {
            self.isDragging = false
            if operation != [], !insideOwnWindow {
                self.onDragCompleted?(operation)
            }
        }
    }
}
