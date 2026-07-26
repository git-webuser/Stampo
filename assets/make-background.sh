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

# Reset the dpi as well as the pixel size. A 4x Figma export carries 288 dpi, and
# sips passes that through, which makes tiffutil see two different *point* sizes
# and refuse the hidpi pairing. Both representations must be 72 dpi going in;
# tiffutil then labels the 2x one 144 dpi itself.
sips -z 400 660 -s dpiWidth 72 -s dpiHeight 72 "$MASTER" --out "$ONE" >/dev/null
sips -z 800 1320 -s dpiWidth 72 -s dpiHeight 72 "$MASTER" --out "$TWO" >/dev/null
echo "  derived: 660x400 and 1320x800 at 72 dpi"

tiffutil -cathidpicheck "$ONE" "$TWO" -out "$OUT"
echo "Wrote $OUT ($(du -h "$OUT" | awk '{print $1}'))"
echo "Commit it together with the master, then ./release.sh <version> will use it."
