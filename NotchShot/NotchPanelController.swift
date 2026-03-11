import AppKit
import SwiftUI
import Combine
import CoreGraphics
import QuartzCore
import ImageIO

// MARK: - Interaction state

final class NotchPanelInteractionState: ObservableObject {
    @Published var isEnabled: Bool = true
    @Published var contentVisibility: Double = 1.0
}

// MARK: - Root state

private enum NotchPanelRoute {
    case main
    case tray
}

private final class NotchPanelRootState: ObservableObject {
    @Published var route: NotchPanelRoute = .main
    @Published var metrics: NotchMetrics = .fallback()
}

private struct NotchPanelRootView: View {
    @ObservedObject var rootState: NotchPanelRootState
    @ObservedObject var interaction: NotchPanelInteractionState
    @ObservedObject var model: NotchPanelModel
    @ObservedObject var trayModel: NotchTrayModel

    let onClose: () -> Void
    let onCapture: (CaptureMode, CaptureDelay) -> Void
    let onToggleTray: () -> Void
    let onPickColor: () -> Void
    let onModeDelayChanged: () -> Void
    let onBack: () -> Void

    var body: some View {
        Group {
            switch rootState.route {
            case .main:
                NotchPanelView(
                    metrics: rootState.metrics,
                    interaction: interaction,
                    model: model,
                    onClose: onClose,
                    onCapture: onCapture,
                    onToggleTray: onToggleTray,
                    onPickColor: onPickColor,
                    onModeDelayChanged: onModeDelayChanged
                )
            case .tray:
                NotchTrayView(
                    metrics: rootState.metrics,
                    trayModel: trayModel,
                    onBack: onBack
                )
            }
        }
    }
}

// MARK: - Panel controller

final class NotchPanelController: NSObject {
    private var panel: NSPanel?
    private var currentScreen: NSScreen?

    private let interactionState = NotchPanelInteractionState()
    private let rootState = NotchPanelRootState()
    private let model = NotchPanelModel()
    private let trayModel = NotchTrayModel()
    private let screenshot = ScreenshotService()
    private let colorPickerHUD = ColorPickerHUD()
    private var activeSampler: ColorSampler?

    private var menuTrackingDepth: Int = 0
    private var trayTransitionInFlight: Bool = false
    private var colorSamplerInFlight: Bool = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidBeginTracking),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidEndTracking),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func menuDidBeginTracking() {
        menuTrackingDepth += 1
    }

    @objc
    private func menuDidEndTracking() {
        menuTrackingDepth = max(0, menuTrackingDepth - 1)
    }

    var suppressesGlobalAutoHide: Bool {
        menuTrackingDepth > 0 || trayTransitionInFlight || colorSamplerInFlight
    }

    private var metrics = NotchMetrics.fallback() {
        didSet {
            rootState.metrics = metrics
        }
    }

    private var route: NotchPanelRoute {
        get { rootState.route }
        set { rootState.route = newValue }
    }

    private var collapsedWidth: CGFloat { metrics.notchGap }

    private var timerDigitsWidth: CGFloat {
        switch model.delay.shortLabel?.count ?? 0 {
        case 0: return 0
        case 1: return 8
        default: return metrics.timerValueWidth
        }
    }

    private var timerCellWidth: CGFloat {
        guard model.delay.shortLabel != nil else {
            return metrics.cellWidth
        }
        return metrics.iconSize + metrics.timerIconToValueGap + timerDigitsWidth + metrics.timerTrailingInsetWithValue
    }

    private var expandedWidth: CGFloat {
        if metrics.hasNotch {
            let timerCell = metrics.iconSize + metrics.timerIconToValueGap + metrics.timerValueWidth + metrics.timerTrailingInsetWithValue

            let leftMin = metrics.edgeSafe
                + metrics.cellWidth + metrics.gap
                + metrics.cellWidth + metrics.gap
                + timerCell
                + metrics.leftMinToNotch

            let rightMin = metrics.rightMinFromNotch
                + metrics.cellWidth + metrics.gap
                + metrics.cellWidth + metrics.gap
                + metrics.captureButtonWidth
                + metrics.edgeSafe

            let shoulder = max(leftMin, rightMin)
            return collapsedWidth + 2 * shoulder
        }

        let left = metrics.edgeSafe
            + metrics.cellWidth + metrics.gap
            + metrics.cellWidth + metrics.gap
            + timerCellWidth

        let right = metrics.edgeSafe
            + metrics.cellWidth + metrics.gap
            + metrics.cellWidth + metrics.gap
            + metrics.captureButtonWidth

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

        interactionState.isEnabled = false
        interactionState.contentVisibility = 0.0
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        if metrics.hasNotch {
            isExpanded = false
            panel.setFrame(frameForWidth(collapsedWidth, on: screen), display: true)

            let target = frameForWidth(clampedWidth(currentWidthForCurrentRoute, on: screen), on: screen)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)

                withAnimation(.easeOut(duration: ctx.duration)) {
                    self.interactionState.contentVisibility = 1.0
                }
                panel.animator().setFrame(target, display: true)
            } completionHandler: { [weak self] in
                self?.interactionState.isEnabled = true
                self?.isExpanded = true
            }
        } else {
            isExpanded = true

            let w = clampedWidth(currentWidthForCurrentRoute, on: screen)
            let hidden = frameNoNotchHiddenAbove(width: w, on: screen)
            let visible = frameForWidth(w, on: screen)
            panel.setFrame(hidden, display: true)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)

                withAnimation(.easeOut(duration: ctx.duration)) {
                    self.interactionState.contentVisibility = 1.0
                }
                panel.animator().setFrame(visible, display: true)
            } completionHandler: { [weak self] in
                self?.interactionState.isEnabled = true
            }
        }
    }

    func hideAnimated() {
        guard let panel, panel.isVisible else { return }

        interactionState.isEnabled = false

        guard let screen = (currentScreen ?? NSScreen.main ?? NSScreen.screens.first) else {
            panel.orderOut(nil)
            interactionState.isEnabled = true
            return
        }

        if metrics.hasNotch {
            isExpanded = false
            let target = frameForWidth(collapsedWidth, on: screen)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

                withAnimation(.easeIn(duration: ctx.duration)) {
                    self.interactionState.contentVisibility = 0.0
                }
                panel.animator().setFrame(target, display: true)
            } completionHandler: { [weak self, weak panel] in
                panel?.orderOut(nil)
                self?.interactionState.isEnabled = true
                self?.isExpanded = false
            }
        } else {
            isExpanded = false
            let w = clampedWidth(currentWidthForCurrentRoute, on: screen)
            let hidden = frameNoNotchHiddenAbove(width: w, on: screen)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)

                withAnimation(.easeIn(duration: ctx.duration)) {
                    self.interactionState.contentVisibility = 0.0
                }
                panel.animator().setFrame(hidden, display: true)
            } completionHandler: { [weak self, weak panel] in
                panel?.orderOut(nil)
                self?.interactionState.isEnabled = true
                self?.isExpanded = false
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
            contentRect: NSRect(x: 0, y: 0, width: collapsedWidth, height: metrics.panelHeight),
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

    private func makeRootView() -> NotchPanelRootView {
        NotchPanelRootView(
            rootState: rootState,
            interaction: interactionState,
            model: model,
            trayModel: trayModel,
            onClose: { [weak self] in self?.hideAnimated() },
            onCapture: { [weak self] mode, delay in
                guard let self else { return }
                let screen = self.currentScreen ?? NSScreen.main
                self.hideAnimated()
                self.screenshot.capture(mode: mode, delaySeconds: delay.seconds, preferredScreen: screen)
            },
            onToggleTray: { [weak self] in self?.switchToTray() },
            onPickColor: { [weak self] in self?.pickColor() },
            onModeDelayChanged: { [weak self] in self?.updateWidthForNoNotchIfNeeded() },
            onBack: { [weak self] in self?.switchToMain() }
        )
    }

    private var currentWidthForCurrentRoute: CGFloat {
        switch route {
        case .main:
            return expandedWidth
        case .tray:
            return trayWidth
        }
    }

    private func switchToTray() {
        guard route != .tray else { return }
        transitionBetweenStates(.tray)
    }

    private func switchToMain() {
        guard route != .main else { return }
        transitionBetweenStates(.main)
    }

    private func transitionBetweenStates(_ targetRoute: NotchPanelRoute) {
        guard let panel else { return }
        guard let screen = currentScreen ?? NSScreen.main else { return }

        trayTransitionInFlight = true
        interactionState.isEnabled = false

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            withAnimation(.easeOut(duration: ctx.duration)) {
                self.interactionState.contentVisibility = 0.0
            }
        } completionHandler: { [weak self, weak panel] in
            guard let self, let panel else { return }

            self.route = targetRoute

            let targetWidth = self.clampedWidth(self.currentWidthForCurrentRoute, on: screen)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(self.frameForWidth(targetWidth, on: screen), display: true)
            } completionHandler: { [weak self] in
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.10
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    withAnimation(.easeOut(duration: ctx.duration)) {
                        self.interactionState.contentVisibility = 1.0
                    }
                } completionHandler: { [weak self] in
                    self?.trayTransitionInFlight = false
                    self?.interactionState.isEnabled = true
                }
            }
        }
    }

    private var trayWidth: CGFloat {
        let baseSide = metrics.edgeSafe
        let swatchWidth: CGFloat = metrics.buttonHeight + 2
        let spacing: CGFloat = 6

        let count = max(1, trayModel.colors.count)
        let contentWidth = CGFloat(count) * swatchWidth + CGFloat(max(0, count - 1)) * spacing

        let schemeControlWidth: CGFloat = 80
        let backButtonWidth: CGFloat = metrics.cellWidth

        if metrics.hasNotch {
            let shoulder = baseSide + backButtonWidth + metrics.gap + schemeControlWidth + metrics.gap + min(contentWidth, 240) + metrics.leftMinToNotch
            return metrics.notchGap + 2 * shoulder
        }

        return baseSide + backButtonWidth + metrics.gap + schemeControlWidth + metrics.gap + min(contentWidth, 300) + baseSide
    }

    @MainActor
    private func pickColor() {
        guard !colorSamplerInFlight else { return }
        colorSamplerInFlight = true

        let screen = currentScreen ?? NSScreen.main

        // Сохраняем sampler как свойство — иначе ARC уничтожит его сразу после выхода из метода
        let sampler = ColorSampler()
        activeSampler = sampler
        colorPickerHUD.beginSession(format: sampler.format)

        // Live preview — на каждый тик мыши
        sampler.onColorChanged = { [weak self] color, position in
            guard let self else { return }
            // Синхронизируем формат (пользователь мог нажать F)
            self.colorPickerHUD.setFormat(sampler.format)
            self.colorPickerHUD.update(color: color, cursorPosition: position)
        }

        // Подтверждение — левый клик
        sampler.onConfirmed = { [weak self] color in
            guard let self else { return }
            self.colorSamplerInFlight = false
            self.activeSampler = nil

            let sRGB = color.usingColorSpace(.sRGB) ?? color

            // Success state: паркуем HUD в угол, показываем «Copied», скрываем через 350 мс
            self.colorPickerHUD.showSuccess(color: sRGB, on: screen, autoHideAfter: 0.35)

            // Копируем в буфер обмена в текущем формате
            let formatted = self.colorPickerHUD.currentFormat.format(sRGB)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(formatted, forType: .string)

            self.trayModel.add(color: sRGB)
            self.switchToTray()
        }

        // Отмена — Escape или правый клик
        sampler.onCancelled = { [weak self] in
            guard let self else { return }
            self.colorSamplerInFlight = false
            self.activeSampler = nil
            self.colorPickerHUD.hide()
            self.switchToMain()
        }

        sampler.start()
    }

    private func updateWidthForNoNotchIfNeeded() {
        guard !metrics.hasNotch else { return }
        guard let panel else { return }
        guard route == .main else { return }
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
        metrics = NotchMetrics.from(screen: screen)
    }

    private func clampedWidth(_ w: CGFloat, on screen: NSScreen) -> CGFloat {
        let maxW = screen.frame.width - 16
        return min(max(w, collapsedWidth), maxW)
    }

    private func frameForWidth(_ width: CGFloat, on screen: NSScreen?) -> NSRect {
        guard let screen else { return NSRect(x: 0, y: 0, width: width, height: metrics.panelHeight) }

        let sf = screen.frame
        let margin = snapToPixel(8, scale: metrics.scale)

        var x = sf.midX - width / 2
        x = max(sf.minX + margin, min(x, sf.maxX - margin - width))
        x = snapToPixel(x, scale: metrics.scale)

        let topInsetNoNotch = snapToPixel(metrics.outerSideInset, scale: metrics.scale)

        let y: CGFloat
        if metrics.hasNotch {
            y = snapToPixel(sf.maxY - metrics.panelHeight, scale: metrics.scale)
        } else {
            y = snapToPixel(screen.visibleFrame.maxY - metrics.panelHeight - topInsetNoNotch, scale: metrics.scale)
        }

        return NSRect(x: x, y: y, width: snapToPixel(width, scale: metrics.scale), height: metrics.panelHeight)
    }

    private func frameNoNotchHiddenAbove(width: CGFloat, on screen: NSScreen?) -> NSRect {
        guard let screen else { return NSRect(x: 0, y: 0, width: width, height: metrics.panelHeight) }

        let sf = screen.frame
        let margin = snapToPixel(8, scale: metrics.scale)

        var x = sf.midX - width / 2
        x = max(sf.minX + margin, min(x, sf.maxX - margin - width))
        x = snapToPixel(x, scale: metrics.scale)

        let y = snapToPixel(sf.maxY + metrics.pixel, scale: metrics.scale)
        return NSRect(x: x, y: y, width: snapToPixel(width, scale: metrics.scale), height: metrics.panelHeight)
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
        autoreleasepool {
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
    }

    /// Требование: стандартная папка Downloads (у каждого пользователя своя).
    private func ensureDownloadsDirectory() -> URL {
        fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? fm.homeDirectoryForCurrentUser
    }

    private func makeFilename() -> String {
        let c = Calendar(identifier: .gregorian)
        let d = c.dateComponents(in: .current, from: Date())

        return String(
            format: "Screenshot %04d-%02d-%02d_%02d-%02d-%02d-%03d.png",
            d.year ?? 0,
            d.month ?? 0,
            d.day ?? 0,
            d.hour ?? 0,
            d.minute ?? 0,
            d.second ?? 0,
            (d.nanosecond ?? 0) / 1_000_000
        )
    }

    private func copyToPasteboard(imageAt url: URL) {
        Task.detached(priority: .userInitiated) {
            let image: NSImage? = autoreleasepool {
                guard
                    let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                    let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil)
                else {
                    return nil
                }

                return NSImage(cgImage: cgImage, size: .zero)
            }

            await MainActor.run {
                let pb = NSPasteboard.general
                pb.clearContents()

                if let image {
                    pb.writeObjects([image, url as NSURL])
                } else {
                    pb.writeObjects([url as NSURL])
                }
            }
        }
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

                if w <= 0 || h <= 0 {
                    continue
                }

                if (w < 60 && h < 60) || (w * h < 3600) {
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

@MainActor
private final class ScreenshotThumbnailLoader: ObservableObject {
    @Published var image: NSImage?

    private var loadedURL: URL?
    private var loadTask: Task<Void, Never>?

    deinit {
        loadTask?.cancel()
    }

    func load(imageURL: URL, maxPixelSize: CGFloat = 440) {
        if loadedURL != imageURL {
            image = nil
            loadedURL = imageURL
        }

        loadTask?.cancel()
        let url = imageURL

        loadTask = Task { @MainActor in
            let nsImage: NSImage? = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    guard
                        let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                        let cgImage = CGImageSourceCreateThumbnailAtIndex(
                            src,
                            0,
                            [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize)
                            ] as CFDictionary
                        )
                    else {
                        return nil
                    }

                    return NSImage(cgImage: cgImage, size: .zero)
                }
            }.value

            guard !Task.isCancelled else { return }
            guard self.loadedURL == url else { return }
            image = nsImage
        }
    }
}

private struct ScreenshotThumbnailView: View {
    let imageURL: URL
    let onDismiss: () -> Void
    let onHoverChanged: (Bool) -> Void

    @StateObject private var loader = ScreenshotThumbnailLoader()
    @State private var dragOffset: CGSize = .zero
    @GestureState private var isDragging: Bool = false

    init(
        imageURL: URL,
        onDismiss: @escaping () -> Void,
        onHoverChanged: @escaping (Bool) -> Void
    ) {
        self.imageURL = imageURL
        self.onDismiss = onDismiss
        self.onHoverChanged = onHoverChanged
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(radius: 18, y: 10)

            if let image = loader.image {
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
                    ProgressView()
                        .controlSize(.small)
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
                Task.detached(priority: .userInitiated) {
                    let image: NSImage? = autoreleasepool {
                        guard
                            let src = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                            let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil)
                        else {
                            return nil
                        }

                        return NSImage(cgImage: cgImage, size: .zero)
                    }

                    await MainActor.run {
                        let pb = NSPasteboard.general
                        pb.clearContents()

                        if let image {
                            pb.writeObjects([image, imageURL as NSURL])
                        } else {
                            pb.writeObjects([imageURL as NSURL])
                        }
                    }
                }
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
        .task(id: imageURL) {
            loader.load(imageURL: imageURL)
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

// MARK: - Pixel snapping

private func snapToPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
    let s = max(scale, 1)
    return (value * s).rounded() / s
}

// MARK: - Notch helpers

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let num = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(num.uint32Value)
    }
}
