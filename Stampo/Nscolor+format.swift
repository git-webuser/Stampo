import AppKit

extension NSColor {
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int(round(c.redComponent * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent  * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    var rgbString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int(round(c.redComponent   * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent  * 255))
        return "\(r) \(g) \(b)"
    }

    var hslString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        let cmax = max(r, g, b), cmin = min(r, g, b), delta = cmax - cmin
        var h: CGFloat = 0
        if delta > 0 {
            if cmax == r      { h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6)) }
            else if cmax == g { h = 60 * ((b - r) / delta + 2) }
            else              { h = 60 * ((r - g) / delta + 4) }
        }
        if h < 0 { h += 360 }
        let l = (cmax + cmin) / 2
        let s = delta == 0 ? 0 : delta / (1 - abs(2 * l - 1))
        return "\(Int(round(h)))° \(Int(round(s * 100)))% \(Int(round(l * 100)))%"
    }

    var hsbString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        let cmax = max(r, g, b), cmin = min(r, g, b), delta = cmax - cmin
        var h: CGFloat = 0
        if delta > 0 {
            if cmax == r      { h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6)) }
            else if cmax == g { h = 60 * ((b - r) / delta + 2) }
            else              { h = 60 * ((r - g) / delta + 4) }
        }
        if h < 0 { h += 360 }
        let sv = cmax == 0 ? 0 : delta / cmax
        return "\(Int(round(h)))° \(Int(round(sv * 100)))% \(Int(round(cmax * 100)))%"
    }

    var cmykString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        let k = 1 - max(r, g, b)
        if k >= 1 { return "0% 0% 0% 100%" }
        let d = 1 - k
        let cv = Int(round(((1 - r - k) / d) * 100))
        let mv = Int(round(((1 - g - k) / d) * 100))
        let yv = Int(round(((1 - b - k) / d) * 100))
        let kv = Int(round(k * 100))
        return "\(cv)% \(mv)% \(yv)% \(kv)%"
    }
}

// MARK: - Reading a colour back

/// Every notation the app prints, it now also reads.
///
/// The decor inspector's colour field shows a colour in whatever notation the
/// user set as their default, and a field that can only be read is half a
/// field — so each formatter above has a parser here, written against its own
/// output rather than against a guess at what people type.
///
/// The numbers are lenient on purpose: separators may be spaces, commas or
/// slashes, the marks (`°`, `%`, `#`) are optional, and `rgb(...)`/`hsl(...)`
/// wrappers are tolerated, because the text arrives from a clipboard as often
/// as from the keyboard.
extension NSColor {
    /// The numbers in a piece of text — or nothing at all, if it carries
    /// letters that are not one of the wrapper words.
    ///
    /// The strictness is the point: without it "#3A7BD5" reads as the three
    /// numbers 3, 7 and 5 and comes back as a nearly black colour instead of
    /// failing, so a hex pasted into a panel set to RGB was accepted and
    /// silently meant something else.
    private static func numbers(in text: String) -> [CGFloat] {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for wrapper in ["cmyk", "rgba", "rgb", "hsla", "hsl", "hsba", "hsb"]
        where body.hasPrefix(wrapper) {
            body.removeFirst(wrapper.count)
            break
        }
        guard !body.contains(where: { $0.isLetter }) else { return [] }
        let cleaned = body
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "°", with: " ")
            .replacingOccurrences(of: "%", with: " ")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
        let pieces = cleaned.split(whereSeparator: { !"0123456789.-".contains($0) })
        return pieces.compactMap { piece -> CGFloat? in
            guard let value = Double(piece) else { return nil }
            return CGFloat(value)
        }
    }

    /// "237 227 217", `rgb(237, 227, 217)`.
    convenience init?(rgbString: String) {
        let parts = NSColor.numbers(in: rgbString)
        guard parts.count == 3, parts.allSatisfy({ $0 >= 0 && $0 <= 255 }) else { return nil }
        self.init(srgbRed: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: 1)
    }

    /// "30° 33% 89%".
    convenience init?(hslString: String) {
        let parts = NSColor.numbers(in: hslString)
        guard parts.count == 3 else { return nil }
        let h = parts[0].truncatingRemainder(dividingBy: 360) / 360
        let s = min(1, max(0, parts[1] / 100))
        let l = min(1, max(0, parts[2] / 100))
        // Through HSB, which is what AppKit takes: the two differ only in how
        // saturation and the third number are defined.
        let brightness = l + s * min(l, 1 - l)
        let saturation = brightness == 0 ? 0 : 2 * (1 - l / brightness)
        self.init(hue: h < 0 ? h + 1 : h, saturation: saturation,
                  brightness: brightness, alpha: 1)
    }

    /// "30° 8% 93%".
    convenience init?(hsbString: String) {
        let parts = NSColor.numbers(in: hsbString)
        guard parts.count == 3 else { return nil }
        let h = parts[0].truncatingRemainder(dividingBy: 360) / 360
        self.init(hue: h < 0 ? h + 1 : h,
                  saturation: min(1, max(0, parts[1] / 100)),
                  brightness: min(1, max(0, parts[2] / 100)), alpha: 1)
    }

    /// "0% 4% 8% 7%".
    convenience init?(cmykString: String) {
        let parts = NSColor.numbers(in: cmykString)
        guard parts.count == 4 else { return nil }
        let values = parts.map { min(1, max(0, $0 / 100)) }
        let k = values[3]
        self.init(srgbRed: (1 - values[0]) * (1 - k),
                  green: (1 - values[1]) * (1 - k),
                  blue: (1 - values[2]) * (1 - k), alpha: 1)
    }
}
