import AppKit
import SwiftUI
import Combine
import CoreGraphics
import QuartzCore

// MARK: - Interaction state

final class NotchPanelInteractionState: ObservableObject {
    @Published var isEnabled: Bool = true
    @Published var contentVisibility: Double = 1.0
}

// MARK: - Panel controller

final class NotchPanelController: NSObject {
    private var panel: NSPanel?
    private var currentScreen: NSScreen?

    private let interactionState = NotchPanelInteractionState()
    private let model = NotchPanelModel()
    
    private enum NotchPanelState {
            case main
            case tray
        }

    private var state: NotchPanelState = .main
    private let trayModel = NotchTrayModel()

    private let screenshot = ScreenshotService()

    // Base sizes
    private let height: CGFloat = 34
    private let cornerRadius: CGFloat = 10
    private let outerSideInset: CGFloat = 5
    private let earInsetNotch: CGFloat = 15

    // Layout constraints
    private let cellWidth: CGFloat = 28
    private let gap: CGFloat = 8
    private let leftMinToNotch: CGFloat = 36
    private let rightMinFromNotch: CGFloat = 12
    private let captureButtonWidth: CGFloat = 71

    // Timer internals
    private let timerOneDigitWidth: CGFloat = 8
    private let timerTwoDigitsWidth: CGFloat = 16
    private let timerValueWidth: CGFloat = 13
    private let timerIconToValueGap: CGFloat = 6
    private let timerTrailingInsetWithValue: CGFloat = 8

    // Dynamic screen metrics
    private var hasNotch: Bool = true
    private var notchGap: CGFloat = 186 // fallback
    private var collapsedWidth: CGFloat { notchGap }

    private var edgeSafe: CGFloat {
        outerSideInset + (hasNotch ? earInsetNotch : 0)
    }

    private var timerCellWidth: CGFloat {
        // Dynamic width matters on no-notch screens so the panel doesn't keep "air".
        // Off -> only icon cell (28pt). 3/5 -> 1 digit. 10 -> 2 digits.
        guard let label = model.delay.shortLabel else { return cellWidth }

        let digitCount = label.count
        let digitsWidth: CGFloat = (digitCount <= 1) ? timerOneDigitWidth : timerTwoDigitsWidth

        // In the view the icon is 24pt inside a 28pt cell. The label itself isn't forced to 28pt,
        // so to keep controller sizing close to the SwiftUI label we use iconSize = cellWidth - 4.
        let iconSize = cellWidth - 4
        return iconSize + timerIconToValueGap + digitsWidth + timerTrailingInsetWithValue
    }

    private var expandedWidth: CGFloat {
        if hasNotch {
            // Notch: “весы” — берём максимальную геометрию, чтобы не плясало
            let timerCell = cellWidth + timerIconToValueGap + timerValueWidth + timerTrailingInsetWithValue

            let leftMin = edgeSafe
                + cellWidth + gap             // close
                + cellWidth + gap             // mode
                + timerCell
                + leftMinToNotch

            let rightMin = rightMinFromNotch
                + cellWidth + gap             // tray
                + cellWidth + gap             // more
                + captureButtonWidth
                + edgeSafe

            let shoulder = max(leftMin, rightMin)
            return collapsedWidth + 2 * shoulder
        }

        // No-notch: ширина зависит от текущей задержки (timerCellWidth)
        let left = edgeSafe
            + cellWidth + gap                 // close
            + cellWidth + gap                 // mode
            + timerCellWidth

        let right = edgeSafe
            + cellWidth + gap                 // tray
            + cellWidth + gap                 // more
            + captureButtonWidth

        return left + right
    }

    private(set) var isExpanded: Bool = false
    var isVisible: Bool { panel?.isVisible == true }

    // MARK: - Public

    func toggleAnimated(on screen: NSScreen) {
        isVisible ? hideAnimated() : showAnimated(on: screen)
    }

    func showAnimated(on screen: NSScreen) {
        currentScreen = screen
        updateScreenMetrics(for: screen)

        if panel == nil { create() }
        guard let panel else { return }

        refreshRootView()

        interactionState.isEnabled = false
        interactionState.contentVisibility = 0.0

        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.22).delay(0.10)) {
                self.interactionState.contentVisibility = 1.0
            }
        }

        panel.alphaValue = 1
        panel.orderFrontRegardless()

        if hasNotch {
            isExpanded = false
            setPanelFrame(panel, width: collapsedWidth, on: screen, animated: false, duration: 0, timing: CAMediaTimingFunction(name: .linear))

            isExpanded = true
            setPanelFrame(
                panel,
                width: clampedWidth(expandedWidth, on: screen),
                on: screen,
                animated: true,
                duration: 0.20,
                timing: CAMediaTimingFunction(name: .easeOut)
            ) { [weak self] in
                self?.interactionState.isEnabled = true
            }
        } else {
            isExpanded = true

            let w = clampedWidth(expandedWidth, on: screen)
            let hidden = frameNoNotchHiddenAbove(width: w, on: screen)
            let visible = frameForWidth(w, on: screen)

            panel.setFrame(hidden, display: true)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(visible, display: true)
            } completionHandler: { [weak self] in
                self?.interactionState.isEnabled = true
            }
        }
    }

    func hideAnimated() {
        guard let panel, panel.isVisible else { return }

        interactionState.isEnabled = false

        DispatchQueue.main.async {
            withAnimation(.easeIn(duration: 0.16)) {
                self.interactionState.contentVisibility = 0.0
            }
        }

        guard let screen = (currentScreen ?? NSScreen.main ?? NSScreen.screens.first) else {
            panel.orderOut(nil)
            interactionState.isEnabled = true
            return
        }

        if hasNotch {
            isExpanded = false
            setPanelFrame(
                panel,
                width: collapsedWidth,
                on: screen,
                animated: true,
                duration: 0.18,
                timing: CAMediaTimingFunction(name: .easeInEaseOut)
            ) { [weak self, weak panel] in
                panel?.orderOut(nil)
                self?.interactionState.isEnabled = true
            }
        } else {
            isExpanded = false
            let w = clampedWidth(expandedWidth, on: screen)
            let hidden = frameNoNotchHiddenAbove(width: w, on: screen)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(hidden, display: true)
            } completionHandler: { [weak self, weak panel] in
                panel?.orderOut(nil)
                self?.interactionState.isEnabled = true
            }
        }
    }

    func isPointInsidePanel(_ point: NSPoint) -> Bool {
        guard let panel else { return false }
        return panel.frame.contains(point)
    }

    // MARK: - Private

    private func create() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: collapsedWidth, height: height),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.appearance = NSAppearance(named: .darkAqua)

        panel.contentView = NSHostingView(rootView: makeRootView())
        self.panel = panel
    }

    private func refreshRootView() {
        guard let hosting = panel?.contentView as? NSHostingView<AnyView> else { return }
        hosting.rootView = makeRootView()
    }

    private func makeRootView() -> AnyView {
        switch state {
        case .main:
            return AnyView(mainPanelView())
        case .tray:
            return AnyView(trayPanelView())
        }
    }

private func mainPanelView() -> NotchPanelView {
        NotchPanelView(
            cornerRadius: cornerRadius,
            hasNotch: hasNotch,
            notchGap: notchGap,
            edgeSafe: edgeSafe,
            leftMinToNotch: leftMinToNotch,
            rightMinFromNotch: rightMinFromNotch,
            interaction: interactionState,
            model: model,
            onClose: { [weak self] in self?.hideAnimated() },
            onCapture: { [weak self] mode, delay in
                guard let self else { return }
                let screen = self.currentScreen ?? NSScreen.main
                self.hideAnimated()
                self.screenshot.capture(mode: mode, delaySeconds: delay.seconds, preferredScreen: screen)
            },
            onToggleTray: { [weak self] in
                self?.switchToTray()
            },
            onPickColor: { [weak self] in
                self?.pickColor()
            },
            onModeDelayChanged: { [weak self] in
                self?.updateWidthForNoNotchIfNeeded()
            }
        )
    }
    
    private func trayPanelView() -> some View {
        NotchTrayView(
            hasNotch: hasNotch,
            notchGap: notchGap,
            edgeSafe: edgeSafe,
            trayModel: trayModel,
            onBack: { [weak self] in
                self?.switchToMain()
            }
        )
    }
    
    private func switchToTray() {
        state = .tray
        refreshRootView()
        animateWidthForCurrentState()
    }

    private func switchToMain() {
        state = .main
        refreshRootView()
        animateWidthForCurrentState()
    }
    
    private func animateWidthForCurrentState() {
        guard let panel else { return }
        guard let screen = currentScreen ?? NSScreen.main else { return }

        let targetWidth: CGFloat

        switch state {
        case .main:
            targetWidth = clampedWidth(expandedWidth, on: screen)
        case .tray:
            targetWidth = clampedWidth(trayWidth, on: screen)
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frameForWidth(targetWidth, on: screen), display: true)
        }
    }
    
    private var trayWidth: CGFloat {
        let baseSide = edgeSafe

        let swatchWidth: CGFloat = 30
        let spacing: CGFloat = 6

        let count = max(1, trayModel.colors.count)
        let contentWidth = CGFloat(count) * swatchWidth
            + CGFloat(max(0, count - 1)) * spacing

        let schemeControlWidth: CGFloat = 80
        let backButtonWidth: CGFloat = 28

        if hasNotch {
            let shoulder = baseSide
                + backButtonWidth
                + 12
                + schemeControlWidth
                + 12
                + min(contentWidth, 240)

            return notchGap + 2 * shoulder
        }

        return baseSide
            + backButtonWidth
            + 12
            + schemeControlWidth
            + 12
            + min(contentWidth, 300)
            + baseSide
    }

    private func pickColor() {
        // Системное "eyedropper" поведение
        let sampler = NSColorSampler()
        sampler.show { [weak self] color in
            guard let self else { return }
            guard let color else { return } // cancelled
            self.trayModel.add(color: color)
            // После пипетки логично показать трей с сохранёнными цветами.
            self.switchToTray()
        }
    }

    private func updateWidthForNoNotchIfNeeded() {
        guard !hasNotch else { return }
        guard let panel else { return }
        guard let screen = currentScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        let w = clampedWidth(expandedWidth, on: screen)
        let target = frameForWidth(w, on: screen)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    private func updateScreenMetrics(for screen: NSScreen) {
        let gap = screen.notchGapWidth
        if gap > 0 {
            hasNotch = true
            notchGap = gap
        } else {
            hasNotch = false
            notchGap = 186
        }
    }

    private func clampedWidth(_ w: CGFloat, on screen: NSScreen) -> CGFloat {
        let maxW = screen.frame.width - 16
        return min(max(w, collapsedWidth), maxW)
    }

    private func setPanelFrame(
        _ panel: NSPanel,
        width: CGFloat,
        on screen: NSScreen,
        animated: Bool,
        duration: TimeInterval,
        timing: CAMediaTimingFunction,
        completion: (() -> Void)? = nil
    ) {
        let target = frameForWidth(width, on: screen)

        guard animated else {
            panel.setFrame(target, display: true)
            completion?()
            return
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = timing
            panel.animator().setFrame(target, display: true)
        } completionHandler: {
            completion?()
        }
    }

    private func frameForWidth(_ width: CGFloat, on screen: NSScreen?) -> NSRect {
        guard let screen else { return NSRect(x: 0, y: 0, width: width, height: height) }

        let sf = screen.frame
        let margin: CGFloat = 8

        var x = sf.midX - width / 2
        x = max(sf.minX + margin, min(x, sf.maxX - margin - width))

        let topInsetNoNotch: CGFloat = 5

        let y: CGFloat
        if hasNotch {
            y = sf.maxY - height
        } else {
            y = screen.visibleFrame.maxY - height - topInsetNoNotch
        }

        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func frameNoNotchHiddenAbove(width: CGFloat, on screen: NSScreen?) -> NSRect {
        guard let screen else { return NSRect(x: 0, y: 0, width: width, height: height) }

        let sf = screen.frame
        let margin: CGFloat = 8

        var x = sf.midX - width / 2
        x = max(sf.minX + margin, min(x, sf.maxX - margin - width))

        let y = sf.maxY + 1
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Screenshot service

final class ScreenshotService {
    private let fm = FileManager.default
    private(set) var lastCaptureURL: URL?

    private let thumbnailHUD = ScreenshotThumbnailHUD()

    func capture(mode: CaptureMode, delaySeconds: Int, preferredScreen: NSScreen?) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.runCapture(mode: mode, preferredScreen: preferredScreen)
        }

        if delaySeconds > 0 {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .seconds(delaySeconds), execute: workItem)
        } else {
            DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
        }
    }

    private func runCapture(mode: CaptureMode, preferredScreen: NSScreen?) {
        let downloads = ensureDownloadsDirectory()
        let filename = makeFilename()
        let finalURL = downloads.appendingPathComponent(filename)

        let tmpURL = fm.temporaryDirectory.appendingPathComponent("notchshot-\(UUID().uuidString).png")

        // "-x" чтобы не было системного UI; звук проигрываем сами после сохранения
        var args: [String] = ["-x"]

        switch mode {
        case .selection:
            args.append(contentsOf: ["-i", "-s"])

        case .window:
            // Системно: снимаем фронтальное окно автоматически.
            if let windowID = FrontmostWindowResolver.frontmostWindowID() {
                args.append(contentsOf: ["-l", String(windowID)])
            } else {
                // Фолбек: интерактивный выбор окна
                args.append(contentsOf: ["-i", "-w"])
            }

        case .screen:
            if let displayID = preferredScreen?.displayID {
                args.append(contentsOf: ["-D", String(displayID)])
            }
        }

        args.append(tmpURL.path)

        let ok = runScreencapture(arguments: args)
        guard ok else { return }
        guard fm.fileExists(atPath: tmpURL.path) else { return } // cancel

        do {
            if fm.fileExists(atPath: finalURL.path) {
                try fm.removeItem(at: finalURL)
            }
            try fm.moveItem(at: tmpURL, to: finalURL)
            lastCaptureURL = finalURL

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                ScreenshotSoundPlayer.play()
                self.copyToPasteboard(imageAt: finalURL)
                self.thumbnailHUD.show(imageURL: finalURL, on: preferredScreen)
            }
        } catch {
            lastCaptureURL = tmpURL
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                ScreenshotSoundPlayer.play()
                self.copyToPasteboard(imageAt: tmpURL)
                self.thumbnailHUD.show(imageURL: tmpURL, on: preferredScreen)
            }
        }
    }

    private func runScreencapture(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Требование: стандартная папка Downloads (у каждого пользователя своя).
    private func ensureDownloadsDirectory() -> URL {
        fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? fm.homeDirectoryForCurrentUser
    }

    private func makeFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Screenshot \(formatter.string(from: Date())).png" // ближе к системному неймингу
    }

    private func copyToPasteboard(imageAt url: URL) {
        guard let img = NSImage(contentsOf: url) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img, url as NSURL])
    }
}

// MARK: - Frontmost window resolver (fixed)

private enum FrontmostWindowResolver {
    static func frontmostWindowID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let isOnscreen = info[kCGWindowIsOnscreen as String] as? Bool, isOnscreen else { continue }
            guard let windowNumber = info[kCGWindowNumber as String] as? UInt32 else { continue }

            // FIX: никаких if-let на Double (не optional)
            if let bounds = info[kCGWindowBounds as String] as? [String: Any] {
                let wAny = bounds["Width"]
                let hAny = bounds["Height"]

                let w: Double = (wAny as? Double) ?? Double((wAny as? CGFloat) ?? 0)
                let h: Double = (hAny as? Double) ?? Double((hAny as? CGFloat) ?? 0)

                if (w > 0 && h > 0) && (w < 60 || h < 60) {
                    continue
                }
            }

            return CGWindowID(windowNumber)
        }

        return nil
    }
}

// MARK: - Screenshot sound (macOS 15-friendly)

private enum ScreenshotSoundPlayer {
    static func play() {
        let candidates: [String] = [
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aiff",
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/screenshot.aiff",
            "/System/Library/Library/Sounds/Screen Capture.aiff",
            "/System/Library/Sounds/Glass.aiff"
        ]

        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let sound = NSSound(contentsOfFile: path, byReference: true) {
                sound.play()
                return
            }
        }
        NSSound.beep()
    }
}

// MARK: - Thumbnail HUD (native-ish)

private final class ScreenshotThumbnailHUD {
    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    private let size = CGSize(width: 220, height: 150)

    func show(imageURL: URL, on screen: NSScreen?) {
        DispatchQueue.main.async {
            self.dismissWorkItem?.cancel()
            self.dismissWorkItem = nil

            let screen = screen ?? NSScreen.main ?? NSScreen.screens.first
            let frame = self.frameBottomRight(on: screen)

            if self.panel == nil {
                self.panel = self.makePanel(frame: frame)
            }

            guard let panel = self.panel else { return }
            panel.setFrame(frame, display: true)

            let view = ScreenshotThumbnailView(
                imageURL: imageURL,
                onDismiss: { [weak self] in self?.hide(animated: true) },
                onHoverChanged: { [weak self] hovering in
                    guard let self else { return }
                    if hovering {
                        self.dismissWorkItem?.cancel()
                        self.dismissWorkItem = nil
                    } else {
                        self.scheduleAutoHide()
                    }
                }
            )

            if let hosting = panel.contentView as? NSHostingView<ScreenshotThumbnailView> {
                hosting.rootView = view
            } else {
                panel.contentView = NSHostingView(rootView: view)
            }

            panel.alphaValue = 0
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }

            self.scheduleAutoHide()
        }
    }

    private func scheduleAutoHide() {
        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hide(animated: true)
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    private func hide(animated: Bool) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        guard let panel else { return }

        if !animated {
            panel.orderOut(nil)
            return
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    private func makePanel(frame: NSRect) -> NSPanel {
        let p = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false // тень в SwiftUI
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = false
        p.appearance = NSAppearance(named: .darkAqua)
        return p
    }

    private func frameBottomRight(on screen: NSScreen?) -> NSRect {
        guard let screen else { return NSRect(x: 0, y: 0, width: size.width, height: size.height) }
        let vf = screen.visibleFrame
        let margin: CGFloat = 18
        let x = vf.maxX - margin - size.width
        let y = vf.minY + margin
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

private struct ScreenshotThumbnailView: View {
    let imageURL: URL
    let onDismiss: () -> Void
    let onHoverChanged: (Bool) -> Void

    @State private var dragOffset: CGSize = .zero
    @GestureState private var isDragging: Bool = false

    var body: some View {
        let image = NSImage(contentsOf: imageURL)

        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(radius: 18, y: 10)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
                    .cornerRadius(12)
                    .padding(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            .padding(8)
                    )
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Screenshot")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(10)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .offset(dragOffset)
        .opacity(opacityForDrag)
        .scaleEffect(scaleForDrag)
        .gesture(dismissDragGesture)
        .onTapGesture {
            NSWorkspace.shared.activateFileViewerSelecting([imageURL])
        }
        .onDrag {
            NSItemProvider(contentsOf: imageURL) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([imageURL as NSURL])
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([imageURL])
            }
            Divider()
            Button("Delete") {
                try? FileManager.default.removeItem(at: imageURL)
                onDismiss()
            }
        }
        .onHover { hovering in
            onHoverChanged(hovering)
        }
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                let t = value.translation
                let distance = hypot(t.width, t.height)
                if distance > 90 {
                    withAnimation(.easeIn(duration: 0.16)) {
                        dragOffset = CGSize(width: t.width * 2.2, height: t.height * 2.2)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                        onDismiss()
                    }
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    private var opacityForDrag: Double {
        let d = min(1.0, Double(hypot(dragOffset.width, dragOffset.height) / 180.0))
        return 1.0 - 0.25 * d
    }

    private var scaleForDrag: CGFloat {
        let d = min(1.0, CGFloat(hypot(dragOffset.width, dragOffset.height) / 220.0))
        return 1.0 - 0.05 * d
    }
}

// MARK: - Tray (colors)

final class NotchTrayModel: ObservableObject {
    @Published private(set) var colors: [TrayColor] = []

    func add(color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        let hex = c.hexString
        if colors.first?.hex == hex { return }
        colors.removeAll { $0.hex == hex }
        colors.insert(TrayColor(color: c, hex: hex), at: 0)
        if colors.count > 8 { colors = Array(colors.prefix(8)) }
    }
}

struct TrayColor: Identifiable, Equatable {
    let id = UUID()
    let color: NSColor
    let hex: String
}

// MARK: - Notch helpers

private extension NSScreen {
    var notchGapWidth: CGFloat {
        guard #available(macOS 12.0, *),
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea else {
            return 0
        }
        let w = frame.width - left.width - right.width
        return max(0, w)
    }

    var displayID: CGDirectDisplayID? {
        guard let num = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(num.uint32Value)
    }
}
