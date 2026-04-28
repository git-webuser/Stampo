import SwiftUI
import AppKit


// MARK: - NotchTrayView

struct NotchTrayView: View {
    let metrics: NotchMetrics
    var trayModel: NotchTrayModel
    let isPinned: Bool
    let onBack: () -> Void
    let onHidePanel: () -> Void
    let onTogglePin: () -> Void

    @AppStorage(AppSettings.Keys.defaultColorFormat) private var scheme: ColorSchemeType = .hex
    @State private var hoveredScreenshotID: UUID?

    private func handleBack() {
        onBack()  // controller drives the content fade-out
    }

    private let panelRounding: CGFloat = 19  // clearance for panel corner radius
    private let innerInset:    CGFloat = 15  // scroll container inset from panel edge
    private let contentInset:  CGFloat = 18  // leading/trailing padding inside scroll content
    private var scrollPadH:    CGFloat { panelRounding + innerInset }
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
                    Spacer()
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
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.3))
            VStack(alignment: .leading, spacing: 1) {
                Text("Nothing Here Yet")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                Text("Screenshots and colors you capture will appear here.")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.white.opacity(0.25))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var scrollContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: cellSpacing) {
                ForEach(trayModel.items) { item in
                    switch item {
                    case .screenshot(let shot):
                        TrayScreenshotCell(
                            shot: shot,
                            height: cellH,
                            badgeBleed: badgeBleed,
                            labelOffset: labelOffset,
                            cornerRadius: metrics.buttonRadius,
                            isHovered: hoveredScreenshotID == shot.id,
                            setHovered: { hovering in
                                if hovering {
                                    hoveredScreenshotID = shot.id
                                } else if hoveredScreenshotID == shot.id {
                                    hoveredScreenshotID = nil
                                }
                            },
                            onOpen: { onHidePanel() },
                            onRemove: { trayModel.remove(id: shot.id) },
                            onMoveToTrash: {
                                trayModel.remove(id: shot.id)
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
                            onRemove: { trayModel.remove(id: c.id) }
                        )
                    }
                }
            }
            .padding(.horizontal, contentInset)
            .padding(.top, badgeBleed)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .mask(
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: contentInset)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: contentInset)
            }
        )
        .padding(.horizontal, innerInset)
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
            .accessibilityLabel(systemName == "xmark.circle.fill" ? "Remove from tray" : (isOn ? "Unpin" : "Pin"))
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
    @State private var isRemoving   = false
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
                TrayDeleteBadge(action: {
                    withAnimation(.easeIn(duration: 0.16)) { isRemoving = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { onRemove() }
                }, isPressed: $isBadgeActive)
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
            .opacity(isRemoving ? 0 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isHovered)
            .animation(.spring(response: 0.15, dampingFraction: 0.7), value: isPressed)
            .animation(.easeIn(duration: 0.16), value: isRemoving)
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

// MARK: - Tray Screenshot Cell

private struct TrayScreenshotCell: View {
    let shot: TrayScreenshot
    let height: CGFloat
    let badgeBleed: CGFloat
    let labelOffset: CGFloat
    let cornerRadius: CGFloat
    let isHovered: Bool
    let setHovered: (Bool) -> Void
    let onOpen: () -> Void
    let onRemove: () -> Void
    let onMoveToTrash: () -> Void

    @State private var loader = ThumbnailLoader()
    @State private var isPressed    = false
    @State private var isRemoving   = false
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
        .opacity(isRemoving ? 0 : (isDragging ? 0.45 : 1))
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isHovered)
        .animation(.spring(response: 0.15, dampingFraction: 0.7), value: isPressed)
        .animation(.easeIn(duration: 0.16), value: isRemoving)
        .overlay {
            TrayDragShim(
                url: shot.url,
                dragImage: loader.image,
                cellSize: CGSize(width: width, height: height),
                isPressed: $isPressed,
                isDragging: $isDragging,
                isHovered: isHovered,
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
            TrayDeleteBadge(action: {
                withAnimation(.easeIn(duration: 0.16)) { isRemoving = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { onRemove() }
            }, isPressed: $isBadgeActive)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .offset(x: badgeBleed, y: -badgeBleed)
        }
        .contextMenu {
            Button("Open") {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.open(shot.url, configuration: cfg)
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
                withAnimation(.easeIn(duration: 0.16)) { isRemoving = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { onMoveToTrash() }
            }
        }
        .task(id: shot.url) { loader.load(imageURL: shot.url) }
        .accessibilityLabel("Screenshot \(shot.url.deletingPathExtension().lastPathComponent)")
        .accessibilityHint("Tap to open, hold to delete")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - PopUpSchemeButtonWrapper

private struct PopUpSchemeButtonWrapper: NSViewRepresentable {
    @Binding var selection: ColorSchemeType
    var onOpen:  () -> Void
    var onClose: () -> Void

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton()
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

private struct TrayDragShim: NSViewRepresentable {
    let url: URL
    let dragImage: NSImage?
    let cellSize: CGSize
    @Binding var isPressed: Bool
    @Binding var isDragging: Bool
    let isHovered: Bool
    let onHoverChange: (Bool) -> Void
    let onTap: () -> Void

    func makeNSView(context: Context) -> TrayDragShimView {
        TrayDragShimView(isPressed: $isPressed, isDragging: $isDragging,
                         isHovered: isHovered, onHoverChange: onHoverChange, onTap: onTap)
    }

    func updateNSView(_ nsView: TrayDragShimView, context: Context) {
        nsView.url = url
        nsView.dragImage = dragImage
        nsView.cellSize = cellSize
        nsView.currentIsHovered = isHovered
        nsView.onHoverChange = onHoverChange
    }
}

final class TrayDragShimView: NSView, NSDraggingSource {
    var url: URL?
    var dragImage: NSImage?
    var cellSize: CGSize = .zero
    /// Size of the top-right corner to leave for the delete badge
    var badgeExcludeSize: CGFloat = 16

    @Binding var isPressed: Bool
    @Binding var isDragging: Bool
    var currentIsHovered: Bool
    var onHoverChange: (Bool) -> Void
    let onTap: () -> Void

    private var mouseDownPoint: NSPoint?

    init(isPressed: Binding<Bool>, isDragging: Binding<Bool>,
         isHovered: Bool, onHoverChange: @escaping (Bool) -> Void, onTap: @escaping () -> Void) {
        self._isPressed = isPressed
        self._isDragging = isDragging
        self.currentIsHovered = isHovered
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
            DispatchQueue.main.async { self.onHoverChange(false) }
        }
    }

    deinit {
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
    }

    private func updateHoverState() {
        guard let window else { return }
        let pt = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        // Include badge bleed zone: badge is offset +bleed right, -bleed up.
        // In flipped coords (y=0 at top, increases down) "up" = negative y.
        let bleed = CGFloat(badgeExcludeSize) // reuse existing constant (16)
        let hoverRect = NSRect(
            x: bounds.minX,
            y: -bleed,                        // extend upward past top edge
            width: bounds.width + bleed,      // extend rightward past right edge
            height: bounds.height + bleed
        )
        let hovering = hoverRect.contains(pt)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentIsHovered != hovering else { return }
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
        guard let url else { return }
        DispatchQueue.main.async {
            self.isPressed = false
            self.isDragging = true
        }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let previewSize = NSSize(width: cellSize.width * 0.75, height: cellSize.height * 0.75)
        item.setDraggingFrame(NSRect(origin: .zero, size: previewSize), contents: dragImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link] : [.move]
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DispatchQueue.main.async { self.isDragging = false }
    }
}
