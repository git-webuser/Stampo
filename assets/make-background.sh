#!/usr/bin/env bash
# Usage: ./assets/make-background.sh [master.png]
#        default master: assets/dmg-background@4x.png
#
# Builds the two-representation TIFF that release.sh hands to create-dmg, so the
# DMG window background stays sharp on Retina displays.
#
# Takes one 2640x1600 export and derives both representations from it: 660x400
# and 1320x800 are exactly 1/4 and 1/2 of the master, so the downscale lands on
# whole pixels with nothing invented. (At these ratios sips is bit-identical to a
# CoreGraphics .high resample — measured — so no extra tooling is warranted.)
#
# See assets/README.md.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
MASTER="${1:-$DIR/dmg-background@4x.png}"
OUT="$DIR/dmg-background.tiff"

if [[ ! -f "$MASTER" ]]; then
  echo "Error: master not found: $MASTER"
  echo "Export the artwork from Figma at 4x (2640x1600) to assets/dmg-background@4x.png"
  exit 1
fi

dim() { sips -g "$1" "$2" | awk -v k="$1:" '$1 == k {print $2}'; }

W=$(dim pixelWidth "$MASTER")
H=$(dim pixelHeight "$MASTER")
if [[ "$W" != "2640" || "$H" != "1600" ]]; then
  echo "Error: $(basename "$MASTER") is ${W}x${H}, expected 2640x1600 (4x of 660x400)"
  exit 1
fi
echo "  master: $(basename "$MASTER") ${W}x${H}"

# Fixed basenames: tiffutil records each input's filename in that
# representation's ImageDescription, and a mktemp name would put build noise
# inside the shipped file.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ONE="$TMP/dmg-background.png"
TWO="$TMP/dmg-background@2x.png"

# Downscale onto opaque white at 72 dpi. Three things have to be true of the
# output and sips alone cannot do the first:
#
#   opaque  A DMG background is drawn over the Finder window's own backdrop,
#           which is dark in dark mode. A Figma export that forgets its
#           background rect would otherwise ship as a see-through window, and the
#           only way to notice is to mount the published DMG on a dark-mode Mac.
#           Compositing onto white here makes that impossible by construction.
#   72 dpi  A 4x export carries 288 dpi. Passed through, tiffutil sees two
#           different *point* sizes and refuses the hidpi pairing; it labels the
#           2x representation 144 dpi itself once both inputs are 72.
#   exact   660x400 and 1320x800 are 1/4 and 1/2 of the master, so the resample
#           lands on whole pixels.
cat > "$TMP/derive.swift" <<'SWIFT'
import AppKit

let master = CommandLine.arguments[1]
guard let rep = NSImage(contentsOfFile: master)?.representations.first as? NSBitmapImageRep,
      let cg = rep.cgImage else {
    FileHandle.standardError.write("cannot decode \(master)\n".data(using: .utf8)!)
    exit(1)
}
for (index, size) in [(660, 400), (1320, 800)].enumerated() {
    let w: Int = size.0
    let h: Int = size.1
    // noneSkipLast drops the alpha channel outright; filling white first is what
    // gives transparent source pixels something to composite against.
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }
    ctx.interpolationQuality = .high
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    let out = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    out.size = NSSize(width: w, height: h)          // = 72 dpi
    guard let png = out.representation(using: .png, properties: [:]) else { exit(1) }
    try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[2 + index]))
}
SWIFT
swift "$TMP/derive.swift" "$MASTER" "$ONE" "$TWO"

for f in "$ONE" "$TWO"; do
  if [[ "$(sips -g samplesPerPixel "$f" | awk '/samplesPerPixel/{print $2}')" != "3" ]]; then
    echo "Error: $(basename "$f") still carries an alpha channel"
    exit 1
  fi
done
echo "  derived: 660x400 and 1320x800, opaque, 72 dpi"

tiffutil -cathidpicheck "$ONE" "$TWO" -out "$OUT"
echo "Wrote $OUT ($(du -h "$OUT" | awk '{print $1}'))"
echo "Commit it together with the master, then ./release.sh <version> will use it."
