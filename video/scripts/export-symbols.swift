// Renders the SF Symbols the clips show — the archive's header, its text
// tiles, the colour HUD's "copied" check — white on transparent into
// public/symbols, at the point size and weight the app draws them with, and
// writes their sizes in points to src/brand/symbols.json.
//
//   swift scripts/export-symbols.swift
//
// The panel's own glyphs are not here: they come as paths in figma/panel.svg.
import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let outDir = root.appendingPathComponent("public/symbols")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// name, point size, weight — as in NotchArchiveView.swift and ColorPickerHUD.swift
let symbols: [(String, CGFloat, NSFont.Weight)] = [
    ("chevron.left", 14, .semibold),
    ("chevron.down", 9, .semibold),
    ("pin", 15, .regular),
    ("text.viewfinder", 8, .semibold),
    ("checkmark.circle", 17, .regular),
]
let scale: CGFloat = 8

var manifest: [String: [String: Double]] = [:]
for (name, size, weight) in symbols {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
          let glyph = base.withSymbolConfiguration(.init(pointSize: size, weight: weight)) else {
        FileHandle.standardError.write(Data("no symbol \(name)\n".utf8)); exit(1)
    }
    let pt = glyph.size
    let px = NSSize(width: ceil(pt.width * scale), height: ceil(pt.height * scale))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let tinted = NSImage(size: pt, flipped: false) { rect in
        glyph.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    tinted.draw(in: NSRect(origin: .zero, size: px))
    NSGraphicsContext.restoreGraphicsState()
    let file = outDir.appendingPathComponent("\(name).png")
    try! rep.representation(using: .png, properties: [:])!.write(to: file)
    manifest[name] = ["w": Double(pt.width), "h": Double(pt.height)]
}
let json = try! JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: root.appendingPathComponent("src/brand/symbols.json"))
print(manifest)
