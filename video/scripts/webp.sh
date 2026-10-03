#!/bin/bash
# Renders the four clips and encodes each as an animated WebP for the README,
# the way the README's onboarding WebPs were made (until 384d92e): 25 fps, the banner's
# rounded corners cut into the alpha, and img2webp settings that keep lossy
# deltas from leaving streaks in the gradients (-exact, a keyframe every ten).
#
#   bash scripts/webp.sh                 all four
#   bash scripts/webp.sh Scan Archive    just these
#
# Each lands in ../assets/screenshots/clip-<name>.webp, where the README
# shows it; the mp4s and frames it is made from stay in out/.
#
# Clip lengths are multiples of 6 frames, so 30 fps resamples to 25 without a
# stray frame at the loop's seam.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p out
[ -f out/mask.png ] || swift scripts/mask.swift out/mask.png

clips=("$@")
[ ${#clips[@]} -eq 0 ] && clips=(Capture Editor Scan Archive)

for clip in "${clips[@]}"; do
  npx remotion render "$clip" "out/$clip.mp4" --crf=10 --log=error
  frames="out/frames-$clip"
  rm -rf "$frames" && mkdir -p "$frames"
  ffmpeg -v error -y -i "out/$clip.mp4" -loop 1 -i out/mask.png \
    -filter_complex "[0:v]fps=25,format=rgba[v];[1:v]format=gray[m];[v][m]alphamerge=shortest=1" \
    "$frames/%04d.png"
  webp="../assets/screenshots/clip-$(echo "$clip" | tr '[:upper:]' '[:lower:]').webp"
  img2webp -loop 0 -lossy -q 80 -m 5 -exact -kmin 9 -kmax 10 -d 40 "$frames"/*.png -o "$webp" >/dev/null 2>&1
  echo "$webp: $(ls "$frames" | wc -l | tr -d ' ') frames, $(( $(stat -f%z "$webp") / 1024 )) KB"
done
