import SwiftUI
import AppKit


// MARK: - NotchTrayView

struct NotchTrayView: View {
    let metrics: NotchMetrics
    @ObservedObject var trayModel: NotchTrayModel
    let onBack: () -> Void

    @AppStorage(AppSettings.Keys.defaultColorFormat) private var scheme: ColorSchemeType = .hex

    private func handleBack() {
        onBack()  // контроллер управляет fade-out контента
    }

    private let panelRounding: CGFloat = 15  // clearance for panel corner radius
    private let innerInset:    CGFloat = 19  // inset from panel edge to first cell
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
                            trayIconButton
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
                    trayIconButton
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
                            onRemove: { trayModel.remove(id: shot.id) }
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
            // innerInset only: the panelRounding portion is now part of the
            // ScrollView's own frame inset below, so the scroll clip boundary
            // sits inside the beveled corners and cells never render over them.
            .padding(.horizontal, innerInset)
            .padding(.top, badgeBleed)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // Inset the scroll frame by panelRounding on each side so its clip boundary
        // aligns with the inner edge of the beveled top corners of the tray shape.
        // scrollClipDisabled() is still needed so hover labels (−18 pt below cells)
        // and delete badges (+3 pt above the HStack) can render outside the scroll rect.
        .padding(.horizontal, panelRounding)
        .scrollClipDisabled()
    }

    // MARK: - Buttons

    private var backButton: some View {
        PanelIconButton(systemName: "chevron.left", size: 14, weight: .semibold, action: handleBack)
            .frame(width: metrics.cellWidth, height: metrics.iconSize)
    }

    private var trayIconButton: some View {
        PanelIconButton(
            systemName: "photo.on.rectangle.angled",
            isActive: true,
            action: handleBack
        )
        .frame(width: metrics.cellWidth, height: metrics.iconSize)
    }

    private var moreButton: some View {
        PanelMoreMenuButton(metrics: metrics)
            .frame(width: metrics.cellWidth, height: metrics.iconSize)
    }

    private var schemeMenu: some View {
        TraySchemeMenuButton(scheme: $scheme, metrics: metrics)
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
    let onRemove: () -> Void

    @StateObject private var loader = ThumbnailLoader()
    @State private var isHovered    = false
    @State private var isPressed    = false
    @State private var isRemoving   = false
    @State private var isBadgeActive = false
    @State private var isDragging   = false

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
                isHovered: $isHovered,
                onTap: {
                    let saveDir = AppSettings.saveDirectoryURL
                    let hasBookmark = UserDefaults.standard.data(
                        forKey: AppSettings.Keys.saveDirectoryBookmark) != nil
                    let accessing = hasBookmark && saveDir.startAccessingSecurityScopedResource()
                    let cfg = NSWorkspace.OpenConfiguration()
                    cfg.activates = true
                    NSWorkspace.shared.open(shot.url, configuration: cfg) { _, _ in
                        if accessing { saveDir.stopAccessingSecurityScopedResource() }
                    }
                }
            )
        }
        .contextMenu {
            Button("Open") {
                let saveDir = AppSettings.saveDirectoryURL
                let hasBookmark = UserDefaults.standard.data(
                    forKey: AppSettings.Keys.saveDirectoryBookmark) != nil
                let accessing = hasBookmark && saveDir.startAccessingSecurityScopedResource()
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.open(shot.url, configuration: cfg) { _, _ in
                    if accessing { saveDir.stopAccessingSecurityScopedResource() }
                }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([shot.url]) }
            Button("Copy") { NSPasteboard.general.writeImage(at: shot.url) }
            Divider()
            Button("Remove from Tray") {
                withAnimation(.easeIn(duration: 0.16)) { isRemoving = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { onRemove() }
            }
        }
        .task(id: shot.url) { loader.load(imageURL: shot.url) }
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

        // pullsDown=true: первый пункт используется как скрытый заголовок кнопки,
        // добавляем пустой placeholder чтобы пункты выбора начинались с HEX.
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
        // +1 — смещение из-за пустого placeholder на индексе 0 (pullsDown = true)
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
            // -1 — компенсируем пустой placeholder на индексе 0 (pullsDown = true)
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
    @Binding var isHovered: Bool
    let onTap: () -> Void

    func makeNSView(context: Context) -> TrayDragShimView {
        TrayDragShimView(isPressed: $isPressed, isDragging: $isDragging,
                         isHovered: $isHovered, onTap: onTap)
    }

    func updateNSView(_ nsView: TrayDragShimView, context: Context) {
        nsView.url = url
        nsView.dragImage = dragImage
        nsView.cellSize = cellSize
    }
}

final class TrayDragShimView: NSView, NSDraggingSource {
    var url: URL?
    var dragImage: NSImage?
    var cellSize: CGSize = .zero
    /// Size of the top-right corner to leave for the delete badge
    var badgeExcludeSize: CGFloat = 22

    @Binding var isPressed: Bool
    @Binding var isDragging: Bool
    @Binding var isHovered: Bool
    let onTap: () -> Void

    private var mouseDownPoint: NSPoint?
    private var dragAccessing = false

    init(isPressed: Binding<Bool>, isDragging: Binding<Bool>,
         isHovered: Binding<Bool>, onTap: @escaping () -> Void) {
        self._isPressed = isPressed
        self._isDragging = isDragging
        self._isHovered = isHovered
        self.onTap = onTap
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Match SwiftUI coordinate system: origin top-left, y increases downward
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func layout() {
        super.layout()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        guard !bounds.isEmpty else { return }
        // isFlipped=true: origin top-left, y increases downward.
        // The badge is rendered above the cell (y < 0) via SwiftUI offset.
        // Extend the tracking rect upward so mouseEntered/Exited stays true
        // while the cursor is over the badge.
        let bleed = badgeExcludeSize
        let expanded = bounds.union(NSRect(x: bounds.maxX - bleed,
                                           y: -bleed,
                                           width: bleed + bleed,
                                           height: bleed))
        addTrackingArea(NSTrackingArea(
            rect: expanded,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        DispatchQueue.main.async { self.isHovered = true }
    }

    override func mouseExited(with event: NSEvent) {
        DispatchQueue.main.async { self.isHovered = false }
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
            if hypot(current.x - start.x, current.y - start.y) < 5 { onTap() }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let url else { return }
        DispatchQueue.main.async {
            self.isPressed = false
            self.isDragging = true
        }
        // Sandbox requires the source app to hold an active security scope for
        // the file while the drag session runs so the destination can read it.
        let saveDir = AppSettings.saveDirectoryURL
        let hasBookmark = UserDefaults.standard.data(
            forKey: AppSettings.Keys.saveDirectoryBookmark) != nil
        dragAccessing = hasBookmark && saveDir.startAccessingSecurityScopedResource()

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
        if dragAccessing {
            AppSettings.saveDirectoryURL.stopAccessingSecurityScopedResource()
            dragAccessing = false
        }
        DispatchQueue.main.async { self.isDragging = false }
    }
}
