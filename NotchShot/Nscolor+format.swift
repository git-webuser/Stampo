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
