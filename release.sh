#!/usr/bin/env bash
# Usage: ./release.sh <version>  e.g. ./release.sh 0.2.0-beta.1
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: ./release.sh <version>"
  echo "Example: ./release.sh 0.2.0-beta.1"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PBXPROJ="$SCRIPT_DIR/Stampo.xcodeproj/project.pbxproj"
BUILD_DIR="$SCRIPT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/Stampo.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
DMG_PATH="$BUILD_DIR/Stampo-${VERSION}.dmg"

# ---------- pre-flight ----------

if ! command -v create-dmg &>/dev/null; then
  echo "Error: create-dmg not found. Run: brew install create-dmg"
  exit 1
fi

if ! command -v gh &>/dev/null; then
  echo "Error: gh not found. Run: brew install gh"
  exit 1
fi

if [[ -n "$(git -C "$SCRIPT_DIR" status --porcelain)" ]]; then
  echo "Error: uncommitted changes. Commit or stash first."
  exit 1
fi

# ---------- version bump ----------

CURRENT_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION' "$PBXPROJ" | sed 's/.*= //;s/;//;s/[[:space:]]//g')
NEW_BUILD=$((CURRENT_BUILD + 1))

echo "▸ Bumping version: $VERSION (build $NEW_BUILD)"

sed -i '' "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = $VERSION/" "$PBXPROJ"
sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*/CURRENT_PROJECT_VERSION = $NEW_BUILD/" "$PBXPROJ"

git -C "$SCRIPT_DIR" add Stampo.xcodeproj/project.pbxproj
git -C "$SCRIPT_DIR" commit -m "Bump version to $VERSION (build $NEW_BUILD)"
git -C "$SCRIPT_DIR" tag "$VERSION"
git -C "$SCRIPT_DIR" push origin HEAD
git -C "$SCRIPT_DIR" push origin "$VERSION"

# ---------- build ----------

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH" "$DMG_PATH"
mkdir -p "$BUILD_DIR"

echo "▸ Archiving (this takes a minute)..."
xcodebuild archive \
  -scheme Stampo \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -quiet

echo "▸ Exporting..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$SCRIPT_DIR/ExportOptions.plist" \
  -quiet

codesign --verify --deep --strict "$EXPORT_PATH/Stampo.app"
echo "  Signature OK"

# ---------- DMG ----------

echo "▸ Creating DMG..."
create-dmg \
  --volname "Stampo" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 100 \
  --icon "Stampo.app" 200 190 \
  --hide-extension "Stampo.app" \
  --app-drop-link 460 190 \
  "$DMG_PATH" \
  "$EXPORT_PATH/"

CHECKSUM=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

# ---------- GitHub Release ----------

echo "▸ Creating GitHub Release..."

NOTES="## Stampo $VERSION

> ⚠️ Этот билд не нотаризован. При первом запуске macOS покажет предупреждение.
> Правый клик → Открыть (Open) чтобы запустить.

### Что нового
-

### Совместимость
- macOS 15.7 и новее
- MacBook с вырезом (MacBook Pro 14\"/16\", MacBook Air M2+)

### Checksum
\`SHA256: $CHECKSUM\`"

gh release create "$VERSION" \
  --title "Stampo $VERSION" \
  --notes "$NOTES" \
  --prerelease \
  "$DMG_PATH"

# ---------- Homebrew cask ----------

CASK="$SCRIPT_DIR/Casks/stampo.rb"
if [[ -f "$CASK" ]]; then
  echo "▸ Updating Homebrew cask..."
  sed -i '' "s/^  version \".*\"/  version \"$VERSION\"/" "$CASK"
  sed -i '' "s/^  sha256 \".*\"/  sha256 \"$CHECKSUM\"/" "$CASK"
  git -C "$SCRIPT_DIR" add "$CASK"
  git -C "$SCRIPT_DIR" commit -m "Update Homebrew cask to $VERSION"
  git -C "$SCRIPT_DIR" push origin HEAD
fi

# ---------- done ----------

echo ""
echo "✓ Released Stampo $VERSION"
echo "  DMG:    $DMG_PATH"
echo "  SHA256: $CHECKSUM"
echo "  URL:    $(gh release view "$VERSION" --json url -q .url)"
