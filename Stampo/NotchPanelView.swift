import SwiftUI
import AppKit


// MARK: - CaptureMode

enum CaptureMode: CaseIterable, Equatable {
    case selection
    case window
    case screen

    func localizedTitle(_ locale: Locale = LocaleManager.shared.locale) -> String {
        switch self {
        case .selection: return LocaleManager.string("Selection",     locale: locale)
        case .window:    return LocaleManager.string("Window",        locale: locale)
        case .screen:    return LocaleManager.string("Entire Screen", locale: locale)
        }
    }
    var title: String { localizedTitle() }

    var icon: String {
        switch self {
        case .selection: return "rectangle.dashed"
        case .window:    return "macwindow"
        case .screen:    return "menubar.dock.rectangle"
        }
    }

    var shortLabel: String {
        switch self {
        case .selection: return "Sel"
        case .window:    return "Win"
        case .screen:    return "Full"
        }
    }
}

// MARK: - CaptureDelay

enum CaptureDelay: CaseIterable, Equatable {
    case off, s3, s5, s10

    var seconds: Int {
        switch self {
        case .off:  return 0
        case .s3:   return 3
        case .s5:   return 5
        case .s10:  return 10
        }
    }

    func localizedTitle(_ locale: Locale = LocaleManager.shared.locale) -> String {
        switch self {
        case .off:  return LocaleManager.string("No Delay",   locale: locale)
        case .s3:   return LocaleManager.string("3 Seconds",  locale: locale)
        case .s5:   return LocaleManager.string("5 Seconds",  locale: locale)
        case .s10:  return LocaleManager.string("10 Seconds", locale: locale)
        }
    }
    var title: String { localizedTitle() }

    var shortLabel: String? {
        switch self {
        case .off:  return nil
        case .s3:   return "3"
        case .s5:   return "5"
        case .s10:  return "10"
        }
    }
}

// MARK: - NotchPanelModel

@Observable final class NotchPanelModel {
    var mode: CaptureMode   = AppSettings.defaultCaptureMode
    var delay: CaptureDelay = AppSettings.defaultTimerDelay
}

// MARK: - NotchPanelView

struct NotchPanelView: View {
    let metrics: NotchMetrics

    var interaction: NotchPanelInteractionState
    var model: NotchPanelModel

    let isArchiveOpen: Bool

    let onClose: () -> Void
    let onCapture: (_ mode: CaptureMode, _ delay: CaptureDelay) -> Void
    let onToggleArchive: () -> Void
    let onPickColor: () -> Void
    let onScan: () -> Void
    let onModeDelayChanged: () -> Void

    var body: some View {
        Group {
            if metrics.hasNotch {
                notchLayout
            } else {
                noNotchLayout
            }
        }
        .frame(height: metrics.panelHeight)
        .allowsHitTesting(interaction.isEnabled)
        .animation(nil, value: interaction.isEnabled)
        .onChange(of: model.delay) { _, _ in onModeDelayChanged() }
        .onChange(of: model.mode)  { _, _ in onModeDelayChanged() }
    }

    // MARK: - Notch layout

    private var notchLayout: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let shoulders = max(0, (totalWidth - metrics.notchGap) / 2)

            ZStack {
                HStack(spacing: 0) {
                    HStack(spacing: metrics.gap) {
                        closeCell
                        modeMenuCell
                        timerMenuCell
                    }
                    .padding(.leading, metrics.edgeSafe)
                    .padding(.trailing, metrics.leftMinToNotch)
                    .frame(width: shoulders, alignment: .leading)

                    Color.clear
                        .frame(width: metrics.notchGap)
                        .contentShape(Rectangle())
                        .onTapGesture { onClose() }
                        // A mouse shortcut over the notch itself, not a control:
                        // closeCell already exposes closing, so announcing this
                        // as a second unlabelled element would only add noise.
                        .accessibilityHidden(true)

                    HStack(spacing: metrics.gap) {
                        archiveButtonCell
                        moreCell
                        captureButton
                    }
                    .padding(.leading, metrics.rightMinFromNotch)
                    .padding(.trailing, metrics.edgeSafe)
                    .frame(width: shoulders, alignment: .trailing)
                }
                .frame(height: metrics.panelHeight)
                // No .animation(value:) here: contentVisibility's animation is
                // owned by the controller (PanelTiming.contentFadeIn/Out) — a
                // view-level animation would override those transactions and
                // fade the buttons in while the shoulders are still squeezed.
                .opacity(contentOpacity)
            }
        }
    }

    // MARK: - No-notch layout

    private var noNotchLayout: some View {
        ZStack {
            HStack(spacing: metrics.gap) {
                closeCell
                modeMenuCell
                timerMenuCell
                archiveButtonCell
                moreCell
                captureButton
            }
            .padding(.horizontal, metrics.edgeSafe)
            .frame(height: metrics.panelHeight)
            // Controller-owned animation (see notchLayout).
            .opacity(contentOpacity)
        }
        .animation(nil, value: model.delay)
        .animation(nil, value: model.mode)
    }

    // MARK: - Cells

    private var closeCell: some View {
        PanelIconButton(
            systemName: "xmark.circle.fill",
            size: 14,
            weight: .semibold,
            action: onClose
        )
        .frame(width: metrics.cellWidth, height: metrics.iconSize)
        .help("Close panel")
        .accessibilityLabel("Close panel")
    }

    private var modeMenuCell: some View {
        PanelModeMenuButton(
            model: model,
            metrics: metrics,
            onPickColor: onPickColor,
            onScan: onScan
        )
        .animation(nil, value: model.mode)
        .help("Capture mode")
        // No .accessibilityLabel here: the cell is a ZStack around an
        // NSPopUpButton, so the label that actually reaches VoiceOver is the
        // AppKit one the wrapper sets (label + value, kept in sync in
        // updateNSView). A SwiftUI label on the container would either be
        // dropped or shadow the localized AppKit one.
    }

    private var timerMenuCell: some View {
        let shortLabel = model.delay.shortLabel
        return PanelTimerMenuButton(
            model: model,
            metrics: metrics,
            digitsWidth: metrics.timerDigitsWidth(for: shortLabel),
            hasValue: shortLabel != nil,
            cellWidth: metrics.timerCellWidth(for: shortLabel)
        )
        .animation(nil, value: model.delay)
        .help("Capture delay")
        // Labelled from AppKit, like the mode cell above.
    }

    private var archiveButtonCell: some View {
        PanelIconButton(
            systemName: "photo.on.rectangle.angled",
            size: 14,
            weight: .semibold,
            isActive: isArchiveOpen,
            action: onToggleArchive
        )
        .frame(width: metrics.cellWidth, height: metrics.iconSize)
        .help(isArchiveOpen ? "Hide archive" : "Show archive")
        .accessibilityLabel(isArchiveOpen ? "Hide archive" : "Show archive")
    }

    private var moreCell: some View {
        PanelMoreMenuButton(metrics: metrics)
            .frame(width: metrics.cellWidth, height: metrics.iconSize)
            .help("Settings and quit")
            // Labelled from AppKit, like the mode and delay cells.
    }

    private var captureButton: some View {
        PanelCaptureButton(
            metrics: metrics,
            action: { onCapture(model.mode, model.delay) }
        )
        // The button carries visible text, so SwiftUI derives its label from
        // that — an explicit label could only drift out of sync with what the
        // user reads and says to Voice Control. That one word is thin on its
        // own, so the tooltip and the hint both spell the action out.
        .help("Capture in \(model.mode.title) mode")
        .accessibilityHint("Capture in \(model.mode.title) mode")
    }

    // MARK: - Helpers

    private var contentOpacity: Double {
        let t = interaction.contentVisibility
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        return max(0, (t - 0.15) / 0.85)
    }
}

// MARK: - PopUpModeButtonWrapper

private struct PopUpModeButtonWrapper: NSViewRepresentable {
    @Binding var selection: CaptureMode
    var onPickColor: () -> Void
    var onScan: () -> Void
    var onOpen:  () -> Void
    var onClose: () -> Void
    @Environment(\.locale) private var locale

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = PanelPopUpButton()
        button.isBordered        = false
        button.isTransparent     = true
        // Pull-down, not pop-up: a pop-up menu positions itself so the selected
        // item lands over the button, which at the top edge of the screen means
        // starting above the screen — AppKit's fallback there is to scroll the
        // menu and hide the items that don't fit. A pull-down always drops
        // below, so every item stays reachable whatever is selected.
        button.pullsDown         = true
        button.autoresizingMask  = []
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        // A pull-down doesn't mark a "current" item on its own, and the menu
        // mixes modes with two plain commands — so the checkmark is ours to
        // place, on the modes only.
        (button.cell as? NSPopUpButtonCell)?.altersStateOfSelectedItem = false

        // pullsDown=true: item 0 acts as the (never shown) button title, so an
        // empty placeholder goes first and every real index shifts by one.
        button.addItem(withTitle: "")
        for mode in CaptureMode.allCases {
            button.addItem(withTitle: mode.localizedTitle(locale))
        }
        button.menu?.addItem(.separator())
        let pickItem = NSMenuItem(
            title: LocaleManager.string("Pick Color", locale: locale),
            action: #selector(Coordinator.pickColorTapped),
            keyEquivalent: ""
        )
        button.menu?.addItem(pickItem)
        let scanItem = NSMenuItem(
            title: LocaleManager.string("Scan", locale: locale),
            action: #selector(Coordinator.scanTapped),
            keyEquivalent: ""
        )
        button.menu?.addItem(scanItem)

        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        pickItem.target = context.coordinator
        scanItem.target = context.coordinator

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
        // Refresh titles when locale changes, and carry the checkmark.
        // +1 throughout — offset for the placeholder at index 0.
        for (idx, mode) in CaptureMode.allCases.enumerated() {
            let item = button.item(at: idx + 1)
            item?.title = mode.localizedTitle(locale)
            item?.state = (mode == selection) ? .on : .off
        }
        // Label and value live here rather than in makeNSView so they follow
        // both the language and the selection. Set explicitly instead of
        // leaning on the cell's implicit value: the button is transparent and
        // borderless, and the mode is the one thing VoiceOver must announce.
        button.setAccessibilityLabel(LocaleManager.string("Capture mode", locale: locale))
        button.setAccessibilityValue(selection.localizedTitle(locale))
        // Separator is at allCases.count + 1, Pick Color at + 2, Scan at + 3.
        button.item(at: CaptureMode.allCases.count + 2)?.title =
            LocaleManager.string("Pick Color", locale: locale)
        button.item(at: CaptureMode.allCases.count + 3)?.title =
            LocaleManager.string("Scan", locale: locale)

        let idx = (CaptureMode.allCases.firstIndex(of: selection) ?? 0) + 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            button.selectItem(at: idx)
        }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: PopUpModeButtonWrapper

        init(_ parent: PopUpModeButtonWrapper) { self.parent = parent }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let cases = CaptureMode.allCases
            // -1 — compensate for the empty placeholder at index 0 (pullsDown = true)
            let idx = sender.indexOfSelectedItem - 1
            guard idx >= 0, idx < cases.count else { return }
            DispatchQueue.main.async { self.parent.selection = cases[idx] }
        }

        @objc func pickColorTapped() {
            DispatchQueue.main.async { self.parent.onPickColor() }
        }

        @objc func scanTapped() {
            DispatchQueue.main.async { self.parent.onScan() }
        }

        @objc func menuWillOpen(_ notification: Notification) {
            DispatchQueue.main.async { self.parent.onOpen() }
        }

        @objc func menuDidClose(_ notification: Notification) {
            DispatchQueue.main.async { self.parent.onClose() }
        }
    }
}

// MARK: - PopUpButtonWrapper

private struct PopUpButtonWrapper: NSViewRepresentable {
    @Binding var selection: CaptureDelay
    var onOpen:  () -> Void
    var onClose: () -> Void
    @Environment(\.locale) private var locale

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = PanelPopUpButton()
        button.isBordered        = false
        button.isTransparent     = true
        // Pull-down for the same reason as the mode menu: see
        // PopUpModeButtonWrapper.makeNSView. The delay list is the worse case —
        // picking "10 Seconds" would ask a pop-up for three rows above the
        // screen edge.
        button.pullsDown         = true
        button.autoresizingMask  = []
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        (button.cell as? NSPopUpButtonCell)?.altersStateOfSelectedItem = false

        button.addItem(withTitle: "")
        for delay in CaptureDelay.allCases {
            button.addItem(withTitle: delay.localizedTitle(locale))
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
        // Refresh titles when locale changes, and carry the checkmark.
        // +1 throughout — offset for the placeholder at index 0.
        for (idx, delay) in CaptureDelay.allCases.enumerated() {
            let item = button.item(at: idx + 1)
            item?.title = delay.localizedTitle(locale)
            item?.state = (delay == selection) ? .on : .off
        }
        // See PopUpModeButtonWrapper.updateNSView on why these live here.
        button.setAccessibilityLabel(LocaleManager.string("Capture delay", locale: locale))
        button.setAccessibilityValue(selection.localizedTitle(locale))
        let idx = (CaptureDelay.allCases.firstIndex(of: selection) ?? 0) + 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            button.selectItem(at: idx)
        }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: PopUpButtonWrapper

        init(_ parent: PopUpButtonWrapper) { self.parent = parent }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let cases = CaptureDelay.allCases
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

// MARK: - PanelModeMenuButton

private struct PanelModeMenuButton: View {
    var model: NotchPanelModel
    let metrics: NotchMetrics
    let onPickColor: () -> Void
    let onScan: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    @State private var isHovered  = false
    @State private var isPressed  = false
    @State private var isMenuOpen = false

    var body: some View {
        @Bindable var model = model
        return ZStack {
            PopUpModeButtonWrapper(
                selection: $model.mode,
                onPickColor: onPickColor,
                onScan: onScan,
                onOpen:  { isMenuOpen = true  },
                onClose: { isMenuOpen = false }
            )
            .frame(width: metrics.cellWidth, height: metrics.iconSize)

            Image(systemName: model.mode.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .frame(width: 24, height: 24)
                .frame(width: metrics.cellWidth, height: metrics.iconSize)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundColor)
                )
                .scaleEffect(isPressed ? 0.88 : 1.0)
                .animation(.spring(response: 0.18, dampingFraction: 0.7), value: isPressed)
                .allowsHitTesting(false)
        }
        .frame(width: metrics.cellWidth, height: metrics.iconSize)
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

    private var foregroundColor: Color {
        if isMenuOpen { return .white }
        if isPressed  { return .white }
        if isHovered  { return .white }
        return PanelChrome.foreground(0.8, contrast)
    }

    private var backgroundColor: Color {
        if isMenuOpen { return PanelChrome.fill(0.22, contrast) }
        if isPressed  { return PanelChrome.fill(0.28, contrast) }
        if isHovered  { return PanelChrome.fill(0.16, contrast) }
        return .clear
    }
}

// MARK: - PanelTimerMenuButton

private struct PanelTimerMenuButton: View {
    var model: NotchPanelModel
    let metrics: NotchMetrics
    let digitsWidth: CGFloat
    let hasValue: Bool
    let cellWidth: CGFloat

    @Environment(\.colorSchemeContrast) private var contrast

    @State private var isHovered  = false
    @State private var isPressed  = false
    @State private var isMenuOpen = false

    var body: some View {
        @Bindable var model = model
        return ZStack {
            PopUpButtonWrapper(
                selection: $model.delay,
                onOpen:  { isMenuOpen = true  },
                onClose: { isMenuOpen = false }
            )
            .frame(width: cellWidth, height: metrics.iconSize)

            HStack(spacing: metrics.timerIconToValueGap) {
                Image(systemName: "timer")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(timerForeground)
                    .frame(width: metrics.iconSize, height: metrics.iconSize)

                if hasValue {
                    Text(model.delay.shortLabel ?? "")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(PanelChrome.foreground(0.9, contrast))
                        .frame(width: digitsWidth, height: 12, alignment: .leading)
                }
            }
            .padding(.leading,  hasValue ? metrics.timerLeadingInsetWithValue  : 0)
            .padding(.trailing, hasValue ? metrics.timerTrailingInsetWithValue : 0)
            .frame(width: cellWidth, height: metrics.iconSize, alignment: hasValue ? .leading : .center)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(timerBackground)
            )
            .scaleEffect(isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: isPressed)
            .allowsHitTesting(false)
        }
        .frame(width: cellWidth, height: metrics.iconSize)
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

    private var timerForeground: Color {
        if isMenuOpen { return .white }
        if isPressed  { return .white }
        if isHovered  { return .white }
        return PanelChrome.foreground(0.8, contrast)
    }

    private var timerBackground: Color {
        if isMenuOpen { return PanelChrome.fill(0.22, contrast) }
        if isPressed  { return PanelChrome.fill(0.28, contrast) }
        if isHovered  { return PanelChrome.fill(0.16, contrast) }
        return .clear
    }
}

// MARK: - PanelCaptureButton

private struct PanelCaptureButton: View {
    let metrics: NotchMetrics
    let action: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Text("Capture")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isPressed || isHovered ? .white : PanelChrome.foreground(0.8, contrast))
                .frame(width: metrics.captureButtonWidth, height: metrics.buttonHeight)
                .background(
                    RoundedRectangle(cornerRadius: metrics.buttonRadius, style: .continuous)
                        .fill(captureBackground)
                )
        }
        .buttonStyle(PanelButtonStyle(isHovered: $isHovered, isPressed: $isPressed))
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }

    private var captureBackground: Color {
        if isPressed { return PanelChrome.fill(0.28, contrast) }
        if isHovered { return PanelChrome.fill(0.22, contrast) }
        return PanelChrome.fill(0.14, contrast)
    }
}

// MARK: - CountdownView

struct CountdownView: View {
    @Environment(\.colorSchemeContrast) private var contrast

    let metrics: NotchMetrics
    var interaction: NotchPanelInteractionState
    let secondsRemaining: Int
    let totalSeconds: Int
    let onStop: () -> Void
    let onCaptureNow: () -> Void

    var body: some View {
        Group {
            if metrics.hasNotch {
                notchLayout
            } else {
                noNotchLayout
            }
        }
        .frame(height: metrics.panelHeight)
        .allowsHitTesting(interaction.isEnabled)
        .animation(nil, value: interaction.isEnabled)
    }

    // MARK: - Notch layout

    private var notchLayout: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let shoulders = max(0, (totalWidth - metrics.notchGap) / 2)

            HStack(spacing: 0) {
                HStack(spacing: metrics.gap) {
                    stopCell
                    arcIndicator
                }
                .padding(.leading, metrics.edgeSafe)
                .padding(.trailing, metrics.leftMinToNotch)
                .frame(width: shoulders, alignment: .leading)

                Color.clear.frame(width: metrics.notchGap)

                HStack(spacing: metrics.gap) {
                    captureNowCell
                }
                .padding(.leading, metrics.rightMinFromNotch)
                .padding(.trailing, metrics.edgeSafe)
                .frame(width: shoulders, alignment: .trailing)
            }
            .frame(height: metrics.panelHeight)
            // Controller-owned animation (see NotchPanelView.notchLayout).
            .opacity(contentOpacity)
        }
    }

    // MARK: - No-notch layout

    private var noNotchLayout: some View {
        HStack(spacing: metrics.gap) {
            stopCell
            arcIndicator
            Spacer()
            captureNowCell
        }
        .padding(.horizontal, metrics.outerSideInset)
        .frame(height: metrics.panelHeight)
        // Controller-owned animation (see NotchPanelView.notchLayout).
        .opacity(contentOpacity)
    }

    // MARK: - Cells

    private var stopCell: some View {
        PanelIconButton(
            systemName: "xmark.circle.fill",
            size: 14,
            weight: .semibold,
            action: onStop
        )
        .frame(width: metrics.cellWidth, height: metrics.iconSize)
    }

    private var arcIndicator: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(PanelChrome.stroke(0.15, contrast), lineWidth: 2)
                    .frame(width: 14, height: 14)

                Circle()
                    .trim(from: 0, to: arcProgress)
                    .stroke(PanelChrome.stroke(0.8, contrast), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1.0), value: arcProgress)
            }
            .frame(width: 24, height: 24)

            // Blur-crossfade: the previous digit dissolves into a blurred form
            // while the new one sharpens out of it (.id forces a view swap so
            // .blurReplace runs on every tick).
            ZStack {
                Text("\(secondsRemaining)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(PanelChrome.foreground(0.9, contrast))
                    .id(secondsRemaining)
                    .transition(.blurReplace)
            }
            .animation(.easeOut(duration: 0.35), value: secondsRemaining)
            .frame(width: metrics.timerValueWidth, alignment: .leading)
        }
    }

    private var captureNowCell: some View {
        PanelCaptureButton(metrics: metrics, action: onCaptureNow)
    }

    // MARK: - Helpers

    /// Elapsed fraction: 0 at start, approaches 1 as countdown ends.
    private var arcProgress: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(totalSeconds - secondsRemaining) / Double(totalSeconds)
    }

    private var contentOpacity: Double {
        let t = interaction.contentVisibility
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        return max(0, (t - 0.15) / 0.85)
    }
}
