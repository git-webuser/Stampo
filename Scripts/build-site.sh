#!/bin/bash
# Assembles the landing page into one folder, the way GitHub Pages serves it:
# site/ as written, plus the artwork and the clips taken from assets/ at build
# time, so nothing is copied into the repository twice.
#
#   bash Scripts/build-site.sh            -> build/site
#   bash Scripts/build-site.sh _site      -> _site (what .github/workflows/pages.yml uploads)
#
# The version on the page is the one in Casks/stampo.rb rather than the
# project's MARKETING_VERSION: release.sh commits the cask only after the DMG
# is up on the release, so the page never names a version that cannot be
# downloaded yet.
set -euo pipefail
cd "$(dirname "$0")/.."

out="${1:-build/site}"
version="$(sed -n 's/^  version "\(.*\)"$/\1/p' Casks/stampo.rb)"
if [[ -z "$version" ]]; then
  echo "error: no version line in Casks/stampo.rb" >&2
  exit 1
fi

rm -rf "$out"
mkdir -p "$out/assets"

# Everything in site/ but its README, which is about the site, not part of it.
for f in site/*; do
  [[ "$(basename "$f")" == README.md ]] && continue
  cp -R "$f" "$out/"
done

cp assets/brand/banner.png assets/brand/banner-ru.png assets/brand/social-preview.png "$out/assets/"
cp assets/screenshots/clip-{capture,editor,scan,archive}.mp4 "$out/assets/"

sed -i.bak "s/@VERSION@/$version/g" "$out/index.html"
rm "$out/index.html.bak"
if grep -q '@VERSION@' "$out"/*.html; then
  echo "error: @VERSION@ left in the page" >&2
  exit 1
fi

# Non-breaking spaces after short Russian words and before dashes — see the
# script for the rules. After the version, which it also binds.
python3 Scripts/site-typography.py "$out"/*.html

echo "Built $out (Stampo $version)"
