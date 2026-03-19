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
    /// 0.0 = Main, 1.0 = Tray
    @Published var progress: CGFloat = 0.0
}

// MARK: - PanelMorphShape
//
// 7 keyframes из Figma (Main + 5 транзитов + Tray).
// progress 0.0→1.0 интерполирует между ними попарно.
// Каждый keyframe — массив из 28 CGFloat (14 точек × 2 координаты).
// Порядок точек одинаков во всех фреймах — только координаты меняются.

private struct PanelMorphShape: Shape {
    var progress: CGFloat
    let pixel: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    // 7 keyframes. Каждый — плоский массив координат точек пути:
    // [x0,y0, cx1,cy1, cx2,cy2, x1,y1, ...] в порядке команд SVG.
    // Путь: M p0 → C p1,p2→p3 → C p4,p5→p6 → C p7,p8→p9 →
    //        L p10 → C p11,p12→p13 → C p14,p15→p16 → C p17,p18→p19 →
    //        L p20 →
    //        C p21,p22→p23 → C p24,p25→p26 → C p27,p28→p29 →
    //        L p30 → C p31,p32→p33 → C p34,p35→p36 → C p37,p38→p39 →
    //        L p40 → close
    // Всего 41 точка = 82 значения на keyframe.

    private static let frames: [[CGFloat]] = [
        // 0: Main (536×34)
        [7,0, 9.80026,0, 11.2004,0, 12.27,0.545, 13.2108,1.024, 13.9757,1.789, 14.455,2.730, 15,3.800, 15,5.200, 15,8,
         15,18,
         15,23.601, 15,26.401, 16.090,28.540, 17.049,30.422, 18.579,31.951, 20.460,32.910, 22.599,34, 25.400,34, 31,34,
         505,34,
         510.601,34, 513.401,34, 515.54,32.910, 517.422,31.951, 518.951,30.422, 519.910,28.540, 521,26.401, 521,23.601, 521,18,
         521,8,
         521,5.200, 521,3.800, 521.545,2.730, 522.024,1.789, 522.789,1.024, 523.730,0.545, 524.800,0, 526.200,0, 529,0,
         536,0, 0,0],
        // 1: Transit 1 (536×45)
        [5.4,0, 8.760,0, 10.441,0, 11.724,0.654, 12.853,1.229, 13.771,2.147, 14.346,3.276, 15,4.560, 15,6.240, 15,9.6,
         15,27.4,
         15,33.561, 15,36.641, 16.199,38.994, 17.254,41.064, 18.936,42.747, 21.006,43.801, 23.359,45, 26.439,45, 32.6,45,
         503.4,45,
         509.561,45, 512.641,45, 514.994,43.801, 517.064,42.747, 518.747,41.064, 519.801,38.994, 521,36.641, 521,33.561, 521,27.4,
         521,9.6,
         521,6.240, 521,4.560, 521.654,3.276, 522.229,2.147, 523.147,1.229, 524.276,0.654, 525.560,0, 527.240,0, 530.6,0,
         536,0, 0,0],
        // 2: Transit 2 (536×56)
        [3.8,0, 7.720,0, 9.681,0, 11.178,0.763, 12.495,1.434, 13.566,2.505, 14.237,3.822, 15,5.320, 15,7.280, 15,11.2,
         15,36.8,
         15,43.521, 15,46.881, 16.308,49.448, 17.458,51.706, 19.294,53.542, 21.552,54.692, 24.119,56, 27.479,56, 34.2,56,
         501.8,56,
         508.521,56, 511.881,56, 514.448,54.692, 516.706,53.542, 518.542,51.706, 519.692,49.448, 521,46.881, 521,43.521, 521,36.8,
         521,11.2,
         521,7.280, 521,5.320, 521.763,3.822, 522.434,2.505, 523.505,1.434, 524.822,0.763, 526.319,0, 528.280,0, 532.2,0,
         536,0, 0,0],
        // 3: Transit 3 (536×67)
        [2.2,0, 6.680,0, 8.921,0, 10.632,0.872, 12.137,1.639, 13.361,2.863, 14.128,4.368, 15,6.079, 15,8.320, 15,12.8,
         15,46.2,
         15,53.481, 15,57.121, 16.417,59.902, 17.663,62.348, 19.652,64.337, 22.098,65.583, 24.879,67, 28.519,67, 35.8,67,
         500.2,67,
         507.481,67, 511.121,67, 513.902,65.583, 516.348,64.337, 518.337,62.348, 519.583,59.902, 521,57.121, 521,53.481, 521,46.2,
         521,12.8,
         521,8.320, 521,6.079, 521.872,4.368, 522.639,2.863, 523.863,1.639, 525.368,0.872, 527.079,0, 529.320,0, 533.8,0,
         536,0, 0,0],
        // 4: Transit 4 (536×78)
        [0.6,0, 5.640,0, 8.161,0, 10.086,0.981, 11.779,1.844, 13.156,3.221, 14.019,4.914, 15,6.839, 15,9.360, 15,14.4,
         15,55.6,
         15,63.441, 15,67.361, 16.526,70.356, 17.868,72.990, 20.010,75.132, 22.644,76.474, 25.639,78, 29.559,78, 37.4,78,
         498.6,78,
         506.441,78, 510.361,78, 513.356,76.474, 515.990,75.132, 518.132,72.990, 519.474,70.356, 521,67.361, 521,63.441, 521,55.6,
         521,14.4,
         521,9.360, 521,6.839, 521.981,4.914, 522.844,3.221, 524.221,1.844, 525.914,0.981, 527.839,0, 530.360,0, 535.4,0,
         536,0, 0,0],
        // 5: Transit 5 (536×89)
        [0,0, 4.659,0, 6.989,0, 8.827,0.761, 11.277,1.776, 13.224,3.723, 14.239,6.173, 15,8.011, 15,10.341, 15,15,
         15,65,
         15,73.401, 15,77.601, 16.635,80.810, 18.073,83.632, 20.368,85.927, 23.190,87.365, 26.399,89, 30.599,89, 39,89,
         497,89,
         505.401,89, 509.601,89, 512.810,87.365, 515.632,85.927, 517.927,83.632, 519.365,80.810, 521,77.601, 521,73.401, 521,65,
         521,15,
         521,10.341, 521,8.011, 521.761,6.173, 522.776,3.723, 524.723,1.776, 527.173,0.761, 529.011,0, 531.341,0, 536,0,
         536,0, 0,0],
        // 6: Tray (536×89)
        [0,0, 4.659,0, 6.989,0, 8.827,0.761, 11.277,1.776, 13.224,3.723, 14.239,6.173, 15,8.011, 15,10.341, 15,15,
         15,63.4,
         15,72.361, 15,76.841, 16.744,80.264, 18.278,83.274, 20.726,85.722, 23.736,87.256, 27.159,89, 31.639,89, 40.6,89,
         495.4,89,
         504.361,89, 508.841,89, 512.264,87.256, 515.274,85.722, 517.722,83.274, 519.256,80.264, 521,76.841, 521,72.361, 521,63.4,
         521,15,
         521,10.341, 521,8.011, 521.761,6.173, 522.776,3.723, 524.723,1.776, 527.173,0.761, 529.011,0, 531.341,0, 536,0,
         536,0, 0,0],
    ]

    func path(in rect: CGRect) -> Path {
        let p = max(0, min(1, progress))

        // Находим два соседних keyframe и локальный t между ними
        let n = CGFloat(Self.frames.count - 1)
        let scaled = p * n
        let i = min(Int(scaled), Self.frames.count - 2)
        let t = scaled - CGFloat(i)

        let a = Self.frames[i]
        let b = Self.frames[i + 1]

        // Высота viewBox у каждого keyframe — последняя y-координата левого нижнего угла
        // (предпоследняя точка p40 = (0,0), значит высота = y последней точки в массиве b)
        // Берём maxY из первого курва, который идёт в нижнюю часть (индекс ~21й y)
        // Проще: интерполируем все координаты линейно
        func lerp(_ ai: CGFloat, _ bi: CGFloat) -> CGFloat { ai + (bi - ai) * t }

        // X масштабируется на ширину панели (SVG viewBox = 536)
        let sx = rect.width / 536
        // Y — 1:1, координаты SVG уже в логических пикселях
        let sy: CGFloat = 1.0

        func pt(_ idx: Int) -> CGPoint {
            CGPoint(
                x: rect.minX + lerp(a[idx * 2],     b[idx * 2])     * sx,
                y: rect.minY - pixel + lerp(a[idx * 2 + 1], b[idx * 2 + 1]) * sy
            )
        }

        var path = Path()
        path.move(to: pt(0))
        path.addCurve(to: pt(3), control1: pt(1), control2: pt(2))
        path.addCurve(to: pt(6), control1: pt(4), control2: pt(5))
        path.addCurve(to: pt(9), control1: pt(7), control2: pt(8))
        path.addLine(to: pt(10))
        path.addCurve(to: pt(13), control1: pt(11), control2: pt(12))
        path.addCurve(to: pt(16), control1: pt(14), control2: pt(15))
        path.addCurve(to: pt(19), control1: pt(17), control2: pt(18))
        path.addLine(to: pt(20))
        path.addCurve(to: pt(23), control1: pt(21), control2: pt(22))
        path.addCurve(to: pt(26), control1: pt(24), control2: pt(25))
        path.addCurve(to: pt(29), control1: pt(27), control2: pt(28))
        path.addLine(to: pt(30))
        path.addCurve(to: pt(33), control1: pt(31), control2: pt(32))
        path.addCurve(to: pt(36), control1: pt(34), control2: pt(35))
        path.addCurve(to: pt(39), control1: pt(37), control2: pt(38))
        path.addLine(to: pt(40))
        path.closeSubpath()
        return path
    }
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

    private var m: NotchMetrics { rootState.metrics }
    private var trayScrollHeight: CGFloat { 55 }
    private var trayH: CGFloat { m.panelHeight + trayScrollHeight }
    private var p: CGFloat { rootState.progress }

    var body: some View {
        ZStack(alignment: .top) {
            // Единый морфирующий фон
            PanelMorphShape(progress: p, pixel: m.pixel)
                .fill(Color.black)
                .compositingGroup()
                .frame(height: trayH)

            // Main — гаснет при p→1
            NotchPanelView(
                metrics: m,
                interaction: interaction,
                model: model,
                isTrayOpen: rootState.route == .tray,
                onClose: onClose,
                onCapture: onCapture,
                onToggleTray: onToggleTray,
                onPickColor: onPickColor,
                onModeDelayChanged: onModeDelayChanged
            )
            .opacity(1.0 - p)
            .allowsHitTesting(p < 0.5)

            // Tray — появляется при p→1
            NotchTrayView(
                metrics: m,
                trayModel: trayModel,
                isTrayActive: true,
                onBack: onBack
            )
            .opacity(p)
            .allowsHitTesting(p >= 0.5)
        }
        .frame(height: trayH)
        .allowsHitTesting(interaction.isEnabled)
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
        screenshot.onCaptured = { [weak self] url in
            self?.trayModel.add(screenshotURL: url)
        }
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

            let target = frameForWidth(clampedWidth(currentWidthForCurrentRoute, on: screen), on: screen, height: trayPanelHeight)
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
            let h = trayPanelHeight
            let hidden = frameNoNotchHiddenAbove(width: w, on: screen, height: h)
            let visible = frameForWidth(w, on: screen, height: h)
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

    func hideAnimated(completion: (() -> Void)? = nil) {
        guard let panel, panel.isVisible else {
            completion?()
            return
        }

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
                self?.route = .main
                self?.rootState.progress = 0.0
                completion?()
            }
        } else {
            isExpanded = false
            let w = clampedWidth(currentWidthForCurrentRoute, on: screen)
            let h = trayPanelHeight
            let hidden = frameNoNotchHiddenAbove(width: w, on: screen, height: h)

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
                self?.route = .main
                self?.rootState.progress = 0.0
                completion?()
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
            contentRect: NSRect(x: 0, y: 0, width: collapsedWidth, height: trayPanelHeight),
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
        case .main:  return expandedWidth
        case .tray:  return trayWidth
        }
    }

    // Панель всегда имеет высоту Tray — анимация через SwiftUI progress, не через setFrame
    private var trayScrollRowHeight: CGFloat { 55 }
    private var trayPanelHeight: CGFloat { metrics.panelHeight + trayScrollRowHeight }

    private func switchToTray() {
        if route == .tray { switchToMain() } else { transitionBetweenStates(.tray) }
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

        route = targetRoute
        let targetProgress: CGFloat = targetRoute == .tray ? 1.0 : 0.0

        // Анимируем только SwiftUI progress — плавный crossfade + slide
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            rootState.progress = targetProgress
        }

        // Ширина панели меняется без анимации frame (высота уже максимальная)
        let targetWidth = clampedWidth(currentWidthForCurrentRoute, on: screen)
        let targetFrame = frameForWidth(targetWidth, on: screen, height: trayPanelHeight)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.25, 1.0)
            panel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            self?.trayTransitionInFlight = false
            self?.interactionState.isEnabled = true
        }
    }

    private var trayWidth: CGFloat {
        // На устройствах с нотчем Tray использует ту же ширину что и Main —
        // контент скроллируется внутри, ширина панели не меняется.
        if metrics.hasNotch {
            return expandedWidth
        }

        let baseSide = metrics.edgeSafe
        let swatchWidth: CGFloat = metrics.buttonHeight + 2
        let shotWidth: CGFloat = swatchWidth * 1.6
        let spacing: CGFloat = 6

        let colorCount = trayModel.colors.count
        let shotCount = trayModel.items.count - colorCount
        let totalCount = max(1, trayModel.items.count)
        let contentWidth = CGFloat(colorCount) * swatchWidth
            + CGFloat(shotCount) * shotWidth
            + CGFloat(max(0, totalCount - 1)) * spacing

        let schemeControlWidth: CGFloat = 68
        let backButtonWidth: CGFloat = metrics.cellWidth

        return baseSide + backButtonWidth + metrics.gap + schemeControlWidth + metrics.gap + min(contentWidth, 300) + baseSide
    }

    @MainActor
    private func pickColor() {
        guard !colorSamplerInFlight else { return }
        colorSamplerInFlight = true

        let screen = currentScreen ?? NSScreen.main

        // Скрываем системный курсор сразу при выборе пункта меню —
        // до анимации скрытия панели. Пользователь уже принял решение,
        // ждать нечего. CursorOverlay.show() потом подхватит состояние.
        CursorOverlay.hideCursorAfterMenuCloses()

        // Запускаем sampler точно после завершения анимации — без magic delay.
        hideAnimated { [weak self] in
            guard let self else { return }

            // Сохраняем sampler как свойство — иначе ARC уничтожит его сразу после выхода из метода
            let sampler = ColorSampler()
            self.activeSampler = sampler
            self.colorPickerHUD.beginSession(format: sampler.format)

            // Live preview — на каждый тик мыши
            sampler.onColorChanged = { [weak self] color, position, magnifier in
                guard let self else { return }
                // Синхронизируем формат (пользователь мог нажать F)
                self.colorPickerHUD.setFormat(sampler.format)
                self.colorPickerHUD.update(color: color, cursorPosition: position, magnifier: magnifier)
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
                // Возвращаемся в main — tray открывается только явно через кнопку
                self.switchToMain()
            }

            // Отмена — Escape или правый клик
            sampler.onCancelled = { [weak self] in
                guard let self else { return }
                self.colorSamplerInFlight = false
                self.activeSampler = nil
                self.colorPickerHUD.hide()
                self.switchToMain()
            }

            // Передаём время клика — игнорируем mouseUp от закрытия меню
            sampler.start()
        }
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

    private func frameForWidth(_ width: CGFloat, on screen: NSScreen?, height: CGFloat? = nil) -> NSRect {
        let h = height ?? metrics.panelHeight
        guard let screen else { return NSRect(x: 0, y: 0, width: width, height: h) }

        let sf = screen.frame
        let margin = snapToPixel(8, scale: metrics.scale)

        var x = sf.midX - width / 2
        x = max(sf.minX + margin, min(x, sf.maxX - margin - width))
        x = snapToPixel(x, scale: metrics.scale)

        let topInsetNoNotch = snapToPixel(metrics.outerSideInset, scale: metrics.scale)

        let y: CGFloat
        if metrics.hasNotch {
            // Панель прижата к верхнему краю экрана; при расширении растёт вниз
            y = snapToPixel(sf.maxY - h, scale: metrics.scale)
        } else {
            y = snapToPixel(screen.visibleFrame.maxY - h - topInsetNoNotch, scale: metrics.scale)
        }

        return NSRect(x: x, y: y, width: snapToPixel(width, scale: metrics.scale), height: snapToPixel(h, scale: metrics.scale))
    }

    private func frameNoNotchHiddenAbove(width: CGFloat, on screen: NSScreen?, height: CGFloat? = nil) -> NSRect {
        let h = height ?? metrics.panelHeight
        guard let screen else { return NSRect(x: 0, y: 0, width: width, height: h) }

        let sf = screen.frame
        let margin = snapToPixel(8, scale: metrics.scale)

        var x = sf.midX - width / 2
        x = max(sf.minX + margin, min(x, sf.maxX - margin - width))
        x = snapToPixel(x, scale: metrics.scale)

        let y = snapToPixel(sf.maxY + metrics.pixel, scale: metrics.scale)
        return NSRect(x: x, y: y, width: snapToPixel(width, scale: metrics.scale), height: snapToPixel(h, scale: metrics.scale))
    }
}


// MARK: - Screenshot service

final class ScreenshotService {
    private let fm = FileManager.default
    private(set) var lastCaptureURL: URL?

    private let thumbnailHUD = ScreenshotThumbnailHUD()

    /// Вызывается на main thread после успешного сохранения скрина.
    var onCaptured: ((URL) -> Void)?

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
                self.onCaptured?(finalURL)
            }
        } catch {
            lastCaptureURL = tmpURL
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                ScreenshotSoundPlayer.play()
                self.copyToPasteboard(imageAt: tmpURL)
                self.thumbnailHUD.show(imageURL: tmpURL, on: preferredScreen)
                self.onCaptured?(tmpURL)
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
private final class HUDThumbnailLoader: ObservableObject {
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

    @StateObject private var loader = HUDThumbnailLoader()
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
