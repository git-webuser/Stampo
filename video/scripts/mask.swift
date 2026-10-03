// White rounded rectangle on black, used as the clips' alpha: the banner's
// corner, 48 px on a 1600 x 800 frame, the same cut the onboarding WebPs had.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments[1]
let (w, h, r) = (1600, 800, 48.0)
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
ctx.setFillColor(gray: 0, alpha: 1)
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
ctx.setFillColor(gray: 1, alpha: 1)
ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
ctx.fillPath()
let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dst)
