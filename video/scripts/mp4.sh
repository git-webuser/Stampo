#!/bin/bash
# Renders the four clips as H.264 for the site (site/ at the repository root).
# A web page can play video, which the README cannot, and the same clip as an
# mp4 is several times lighter than the animated WebP.
#
#   bash scripts/mp4.sh                 all four
#   bash scripts/mp4.sh Scan Archive    just these
#
# Each lands in ../assets/screenshots/clip-<name>.mp4, next to its WebP; the
# frames it is made from stay in out/.
#
# Encoded once, from PNG frames rather than from Remotion's own mp4, and
# tagged BT.709: Remotion's mp4 carries no colour tags, and a browser left to
# guess the matrix shifts the brand blues next to the page's CSS ones.
# 30 fps as rendered — the 25 fps resample is the WebP's, whose frame delays
# come in 10 ms steps.
#
# CRF 20 with aq-mode 3 is for the Decor page's gradient: at x264's defaults
# (CRF 23, aq-mode 1) it breaks into diagonal bands that the source frames do
# not have. It costs about a third more than the defaults — the four clips
# still come to a third of their WebPs.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p out

clips=("$@")
[ ${#clips[@]} -eq 0 ] && clips=(Capture Editor Scan Archive)

for clip in "${clips[@]}"; do
  frames="out/png-$clip"
  rm -rf "$frames"
  npx remotion render "$clip" "$frames" --sequence --image-format=png --log=error
  mp4="../assets/screenshots/clip-$(echo "$clip" | tr '[:upper:]' '[:lower:]').mp4"
  ffmpeg -v error -y -framerate 30 -pattern_type glob -i "$frames/*.png" \
    -vf "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv" \
    -c:v libx264 -preset veryslow -tune animation -crf 20 -x264-params aq-mode=3 \
    -movflags +faststart -an "$mp4"
  echo "$mp4: $(ls "$frames" | wc -l | tr -d ' ') frames, $(( $(stat -f%z "$mp4") / 1024 )) KB"
done
