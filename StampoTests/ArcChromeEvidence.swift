import AppKit
import SwiftUI
import Testing
import Vision
@testable import Stampo

/// Retained measurements of the actual window, not a second implementation of
/// the layout. Screen Recording is unavailable to the ad-hoc hosted test app.
@MainActor enum ArcChromeEvidence {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("build/arc-chrome-evidence", isDirectory: true)

    struct AXNode {
        let role: String
        let text: String
        let frame: NSRect
        let parentFrame: NSRect?
    }

    struct Capture {
        let bitmap: NSBitmapImageRep
        let root: NSView
        let scale: CGFloat
        let url: URL

        /// Coordinates throughout the evidence are points from the cached
        /// window's top-left, including its native titlebar and toolbar.
        func topRect(_ view: NSView) -> NSRect {
            let rect = view.convert(view.bounds, to: root)
            return topRect(rect)
        }

        func topRect(_ rect: NSRect) -> NSRect {
            NSRect(x: rect.minX - root.bounds.minX,
                   y: root.isFlipped ? rect.minY - root.bounds.minY : root.bounds.maxY - rect.maxY,
                   width: rect.width, height: rect.height)
        }

        func rgb(_ point: NSPoint) -> [Int] {
            let x = min(bitmap.pixelsWide - 1, max(0, Int((point.x * scale).rounded(.down))))
            let y = min(bitmap.pixelsHigh - 1, max(0, Int((point.y * scale).rounded(.down))))
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return [] }
            return [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
        }

        func medianRow(y: CGFloat, from left: CGFloat, to right: CGFloat) -> [Int] {
            let colors = stride(from: left, through: right, by: CGFloat(3)).map { rgb(NSPoint(x: $0, y: y)) }
                .filter { $0.count == 3 }
            guard !colors.isEmpty else { return [] }
            return (0..<3).map { channel in colors.map { $0[channel] }.sorted()[colors.count / 2] }
        }
    }

    struct Chrome {
        let card: NSRect
        let panel: NSRect
        let detail: NSRect
        let frameColors: [[Int]]
        let cardColor: [Int]
        let headerInset: CGFloat?
        let headerTopInset: CGFloat?
        let capsuleToCard: CGFloat?
        let capsuleToHeader: CGFloat?
        let cornerMaxDelta: Int
        let markupHeight: CGFloat?
        let metrics: [String: Any]
    }

    static func delta(_ lhs: [Int], _ rhs: [Int]) -> Int {
        guard lhs.count == 3, rhs.count == 3 else { return 255 }
        return zip(lhs, rhs).map { abs($0.0 - $0.1) }.max() ?? 255
    }

    static func rectJSON(_ rect: NSRect) -> [String: CGFloat] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }

    static func views(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { views(in: $0) }
    }

    /// SwiftUI does not publish its text nodes to an in-process AX walk in
    /// this hosted test. Measure its real native focus target instead.
    static func firstHeader(in root: NSView, capture: Capture) -> NSRect? {
        let panel = capture.topRect(root)
        return views(in: root).filter {
            !$0.isHiddenOrHasHiddenAncestor && String(describing: type(of: $0)) == "_FocusRingView"
        }.map { capture.topRect($0) }.filter {
            $0.width > panel.width / 2 && $0.height >= 20 && $0.height <= 40
                && $0.minY >= panel.minY - 1 && $0.minY < panel.minY + 40
        }.min { $0.minY < $1.minY }
    }

    static func recognizedText(_ capture: Capture) throws -> [(text: String, frame: NSRect)] {
        let image = try #require(capture.bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "ru-RU"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return (text, NSRect(x: box.minX * capture.root.bounds.width,
                                 y: (1 - box.maxY) * capture.root.bounds.height,
                                 width: box.width * capture.root.bounds.width,
                                 height: box.height * capture.root.bounds.height))
        }
    }

    static func writeJSON(_ value: Any, name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        let url = folder.appendingPathComponent("\(name).json")
        try data.write(to: url)
        print("ARC CHROME JSON \(url.path)")
    }

    static func capture(_ window: NSWindow, name: String) throws -> Capture {
        var root = try #require(window.contentView)
        while let parent = root.superview { root = parent }
        root.layoutSubtreeIfNeeded()
        let cached = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        let opaque = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: cached.pixelsWide, pixelsHigh: cached.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        opaque.size = root.bounds.size
        let context = try #require(NSGraphicsContext(bitmapImageRep: opaque))
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            root.cacheDisplay(in: root.bounds, to: cached)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            // The content and inspector are transparent. Using the system
            // default here would paint the very color mismatch being measured.
            window.backgroundColor.setFill()
            NSRect(origin: .zero, size: opaque.size).fill()
            let image = NSImage(size: opaque.size)
            image.addRepresentation(cached)
            image.draw(in: NSRect(origin: .zero, size: opaque.size), from: .zero,
                       operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(name).png")
        try #require(opaque.representation(using: .png, properties: [:])).write(to: url)
        print("ARC CHROME PNG \(url.path)")
        let result = Capture(bitmap: opaque, root: root,
                             scale: CGFloat(opaque.pixelsWide) / root.bounds.width, url: url)
        var viewRows: [[String: Any]] = []
        func visit(_ view: NSView, depth: Int) {
            viewRows.append(["class": String(describing: type(of: view)), "depth": depth,
                             "rect": rectJSON(result.topRect(view)), "hidden": view.isHidden,
                             "accessibilityLabel": view.accessibilityLabel() ?? ""])
            for child in view.subviews { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        try writeJSON(viewRows, name: "\(name)-views")
        let nodes = accessibility(window)
        try writeJSON(nodes.map { ["role": $0.role, "text": $0.text, "screenRect": rectJSON($0.frame),
                                   "parentScreenRect": $0.parentFrame.map(rectJSON) ?? [:]] }, name: "\(name)-accessibility")
        return result
    }

    static func accessibility(_ root: Any) -> [AXNode] {
        var found: [AXNode] = []
        var visited: Set<ObjectIdentifier> = []
        func visit(_ object: Any, parentFrame: NSRect?, depth: Int) {
            guard depth < 80, let element = object as? NSAccessibilityProtocol else { return }
            let identity = ObjectIdentifier(element as AnyObject)
            guard visited.insert(identity).inserted else { return }
            let frame = element.accessibilityFrame()
            let text = [element.accessibilityLabel(), element.accessibilityTitle(),
                        element.accessibilityValue() as? String].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: " | ")
            found.append(AXNode(role: element.accessibilityRole()?.rawValue ?? "", text: text,
                                frame: frame, parentFrame: parentFrame))
            for child in element.accessibilityChildren() ?? [] { visit(child, parentFrame: frame, depth: depth + 1) }
        }
        visit(root, parentFrame: nil, depth: 0)
        return found
    }

    static func chrome(_ window: NSWindow, split: FrameSplitController,
                       name: String, open: Bool) throws -> Chrome {
        let capture = try capture(window, name: name)
        let panel = capture.topRect(split.panelHosting.view)
        let detail = capture.topRect(split.detailHosting.view)
        let width = capture.root.bounds.width
        let height = capture.root.bounds.height
        let frameColor = capture.rgb(NSPoint(x: width - 4, y: detail.midY))
        let step = 1 / capture.scale
        // Detect the actual painted card on the quiet part of the white
        // markup strip. These bounds are not reconstructed from the padding.
        let scanY = detail.minY + 20
        let painted = stride(from: detail.minX, through: detail.maxX - step, by: step).filter {
            delta(capture.rgb(NSPoint(x: $0, y: scanY)), frameColor) > 3
        }
        let left = try #require(painted.first, "white card is absent from the cached detail")
        let right = try #require(painted.last) + step
        let scanX = right - 20
        let paintedY = stride(from: detail.minY, through: detail.maxY - step, by: step).filter {
            delta(capture.rgb(NSPoint(x: scanX, y: $0)), frameColor) > 3
        }
        let top = try #require(paintedY.first)
        let bottom = try #require(paintedY.last) + step
        let fillBounds = NSRect(x: left, y: top, width: right - left, height: bottom - top)
        // In dark appearance the separator can match the frame exactly, so
        // fill pixels alone omit the 1pt ring. Repeated native graphics frames
        // identify the real clipped card, independently of its paint colours.
        let graphicsViews = views(in: split.detailHosting.view).filter {
            !$0.isHiddenOrHasHiddenAncestor && String(describing: type(of: $0)) == "_NSGraphicsView"
        }
        let nativeFrames: [NSRect] = graphicsViews.map { capture.topRect($0) }
        let graphicsFrames = nativeFrames.filter {
            $0.width > detail.width / 2 && $0.height > detail.height / 2
        }
        let grouped = Dictionary(grouping: graphicsFrames, by: NSStringFromRect)
        let card = try #require(grouped.values.max { $0.count < $1.count }?.first,
                                "the real card must expose a native clipped graphics frame")
        let cardColor = capture.medianRow(y: card.minY + 54, from: card.minX + 3, to: card.minX + 7)

        var toolbarRows: [[String: Any]] = []
        var capsuleBottoms: [CGFloat] = []
        var itemBottoms: [CGFloat] = []
        for item in window.toolbar?.items ?? [] {
            guard let view = item.view else { continue }
            let control = capture.topRect(view)
            if control.maxY <= detail.minY + 1 { itemBottoms.append(control.maxY) }
            var ancestors: [[String: Any]] = []
            var parent: NSView? = view
            while let current = parent, current !== capture.root {
                let rect = capture.topRect(current)
                let type = String(describing: Swift.type(of: current))
                ancestors.append(["class": type, "rect": rectJSON(rect)])
                if type.localizedCaseInsensitiveContains("glass"), rect.height >= 20, rect.height <= 50,
                   rect.maxY <= detail.minY + 1 { capsuleBottoms.append(rect.maxY) }
                parent = current.superview
            }
            toolbarRows.append(["label": item.label, "control": rectJSON(control), "ancestors": ancestors])
        }
        // The macOS 26 toolbar has no glass view among its items' ancestors, so
        // a runner finds no capsule. The items end where the capsule does (36pt
        // controls, 8pt in), and that bottom is what the gap is measured from.
        let capsuleBottom = capsuleBottoms.max() ?? itemBottoms.max()
        let headerRect = open ? firstHeader(in: split.panelHosting.view, capture: capture) : nil
        // The header has a documented 13pt internal horizontal inset (it
        // stands in as far as the controls in the box under it). The
        // enclosing section/GroupBox remains at the caller's outer padding.
        let headerInset = headerRect.map { $0.minX - panel.minX - 13 }
        let headerTopInset = headerRect.map { $0.minY - panel.minY }
        let points: [(String, NSPoint)] = [
            ("panel-lower-left", NSPoint(x: open ? 4 : card.minX - 4, y: height - 24)),
            ("divider", NSPoint(x: card.minX - 4, y: card.midY)),
            ("right-frame", NSPoint(x: width - 4, y: card.midY)),
            ("bottom-frame", NSPoint(x: card.midX, y: height - 4)),
            ("under-toolbar", NSPoint(x: card.midX, y: card.minY - 4)),
            ("under-card-left", NSPoint(x: card.minX + 4, y: height - 4)),
            ("above-panel", NSPoint(x: open ? panel.midX : 4, y: card.minY - 4))
        ]
        let colors = points.map { capture.rgb($0.1) }
        let colorRows = zip(points, colors).map { point, rgb -> [String: Any] in
            ["name": point.0, "x": point.1.x, "y": point.1.y, "rgb": rgb, "deltaFromRight": delta(rgb, frameColor)]
        }
        var cornerRows: [[String: Any]] = []
        for (corner, origin, sx, sy) in [
            ("top-left", NSPoint(x: card.minX, y: card.minY), CGFloat(1), CGFloat(1)),
            ("top-right", NSPoint(x: card.maxX, y: card.minY), CGFloat(-1), CGFloat(1)),
            ("bottom-left", NSPoint(x: card.minX, y: card.maxY), CGFloat(1), CGFloat(-1)),
            ("bottom-right", NSPoint(x: card.maxX, y: card.maxY), CGFloat(-1), CGFloat(-1))
        ] {
            for distance in [CGFloat(2), 4, 6] {
                for offset in [NSPoint(x: -distance, y: distance), NSPoint(x: distance, y: -distance)] {
                    let point = NSPoint(x: origin.x + offset.x * sx, y: origin.y + offset.y * sy)
                    let rgb = capture.rgb(point)
                    cornerRows.append(["corner": corner, "point": [point.x, point.y], "rgb": rgb,
                                       "deltaFromFrame": delta(rgb, frameColor)])
                }
            }
        }
        let markupTransition = stride(from: CGFloat(30), through: 48, by: step).first { offset in
            delta(capture.rgb(NSPoint(x: card.minX + 5, y: card.minY + offset)), cardColor) > 3
        }
        var ringRows: [[String: Any]] = []
        for (edge, origin, direction) in [
            ("top", NSPoint(x: card.midX, y: card.minY), NSPoint(x: 0, y: 1)),
            ("right", NSPoint(x: card.maxX, y: card.minY + 20), NSPoint(x: -1, y: 0)),
            ("bottom", NSPoint(x: card.midX, y: card.maxY), NSPoint(x: 0, y: -1)),
            ("left", NSPoint(x: card.minX, y: card.minY + 20), NSPoint(x: 1, y: 0))
        ] {
            let samples = stride(from: step / 2, through: 3, by: step).map { offset -> [String: Any] in
                let point = NSPoint(x: origin.x + direction.x * offset, y: origin.y + direction.y * offset)
                return ["inwardPt": offset, "rgb": capture.rgb(point)]
            }
            ringRows.append(["edge": edge, "samples": samples])
        }
        let metrics: [String: Any] = [
            "name": name, "open": open, "window": rectJSON(window.frame),
            "root": rectJSON(capture.root.bounds), "panel": rectJSON(panel), "detail": rectJSON(detail),
            "cardPainted": rectJSON(card), "cardFillPixels": rectJSON(fillBounds), "scale": capture.scale,
            "gaps": ["panelContentLeading": headerInset.map { $0 as Any } ?? "unavailable",
                     "panelContentTop": headerTopInset.map { $0 as Any } ?? "unavailable",
                     "panelToCard": open ? card.minX - panel.maxX : 0,
                     "cardRight": width - card.maxX, "cardBottom": height - card.maxY,
                     "closedCardLeft": card.minX,
                     "capsuleToCard": capsuleBottom.map { (card.minY - $0) as Any } ?? "unavailable",
                     "capsuleToFirstHeader": capsuleBottom.flatMap { bottom in headerRect.map { ($0.minY - bottom) as Any } } ?? "unavailable"],
            "toolbar": toolbarRows, "frameSamples": colorRows,
            "cardColor": cardColor, "cardFrameContrast": delta(cardColor, frameColor),
            "cornerOutsideSamples": cornerRows, "ringCrossSections": ringRows,
            "markupTransitionPt": markupTransition.map { $0 as Any } ?? "unavailable",
            "header": headerRect.map(rectJSON) ?? [:]
        ]
        try writeJSON(metrics, name: name)
        print("ARC CHROME \(name) card=\(card) panel=\(panel) detail=\(detail) right=\(width-card.maxX) bottom=\(height-card.maxY) headerInset=\(String(describing: headerInset)) frameRGB=\(colors) cardRGB=\(cardColor) markupTransition=\(String(describing: markupTransition))")
        return Chrome(card: card, panel: panel, detail: detail, frameColors: colors,
                      cardColor: cardColor, headerInset: headerInset, headerTopInset: headerTopInset,
                      capsuleToCard: capsuleBottom.map { card.minY - $0 },
                      capsuleToHeader: capsuleBottom.flatMap { bottom in headerRect.map { $0.minY - bottom } },
                      cornerMaxDelta: cornerRows.compactMap { $0["deltaFromFrame"] as? Int }.max() ?? 255,
                      markupHeight: markupTransition, metrics: metrics)
    }
}

@MainActor final class ArcOpeningRecorder {
    private let window: NSWindow
    private weak var arcSplit: FrameSplitController?
    private var timer: Timer?
    private var startedAt: TimeInterval = 0
    private var initialWidth: CGFloat = 0
    private var initialPanelFrame: NSRect = .zero
    private(set) var firstShiftMs: Double?
    private(set) var samples: [[String: Double]] = []

    init(window: NSWindow, arcSplit: FrameSplitController?) {
        self.window = window
        self.arcSplit = arcSplit
    }

    private func legacySplit() -> NSSplitView? {
        func splits(_ root: NSView) -> [NSSplitView] {
            (root as? NSSplitView).map { [$0] } ?? [] + root.subviews.flatMap(splits)
        }
        guard let content = window.contentView else { return nil }
        let candidates = splits(content).filter { $0.isVertical && $0.arrangedSubviews.count > 1 }
        return candidates.max { $0.bounds.width < $1.bounds.width }
    }

    var panelPresented: Bool {
        if let arcSplit { return !arcSplit.panelItem.isCollapsed }
        guard let split = legacySplit(), let panel = split.arrangedSubviews.last else { return false }
        return !split.isSubviewCollapsed(panel) && !panel.isHiddenOrHasHiddenAncestor
    }

    private var panelGeometry: (split: NSSplitView, panel: NSView)? {
        if let arcSplit, let panel = arcSplit.splitView.arrangedSubviews.first {
            return (arcSplit.splitView, panel)
        }
        guard let split = legacySplit(), let panel = split.arrangedSubviews.last else { return nil }
        return (split, panel)
    }

    var panelWidth: CGFloat {
        // A collapsed host retains its old 320/360pt frame. Only its exposed
        // portion counts; the native inspector need not resize its detail.
        guard let (split, panel) = panelGeometry,
              !split.isSubviewCollapsed(panel), !panel.isHiddenOrHasHiddenAncestor else { return 0 }
        return max(0, panel.frame.intersection(split.bounds).width)
    }

    func start() {
        initialWidth = panelWidth
        initialPanelFrame = panelGeometry?.panel.frame ?? .zero
        startedAt = ProcessInfo.processInfo.systemUptime
        sample()
        let timer = Timer(timeInterval: 0.008, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func sample() {
        let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        let current = panelWidth
        let geometry = panelGeometry
        let frame = geometry?.panel.frame ?? .zero
        samples.append(["ms": elapsed, "panelWidth": current,
                        "rawPanelX": frame.minX, "rawPanelWidth": frame.width,
                        "collapsed": geometry.map { $0.split.isSubviewCollapsed($0.panel) ? 1 : 0 } ?? 1,
                        "hidden": geometry.map { $0.panel.isHiddenOrHasHiddenAncestor ? 1 : 0 } ?? 1])
        // Unhiding can briefly expose the retained full-width frame before
        // AppKit resets it for animation. Require an actual frame change and
        // positive visible growth, not that stale frame or its reset to zero.
        if firstShiftMs == nil, frame != initialPanelFrame, current - initialWidth > 0.5 {
            firstShiftMs = elapsed
        }
    }

    func stop() { timer?.invalidate(); timer = nil; sample() }
}
