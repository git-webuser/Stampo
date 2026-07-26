#!/usr/bin/env bash
# Usage: ./release.sh <version> [notes-file]
#   e.g. ./release.sh 0.4.2 notes.md
# notes-file (optional): markdown whose contents fill the "Что нового" section
# of the GitHub release. Omit it to leave a placeholder dash.
set -euo pipefail

VERSION="${1:-}"
NOTES_FILE="${2:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: ./release.sh <version> [notes-file]"
  echo "Example: ./release.sh 0.4.2 notes.md"
  exit 1
fi
if [[ -n "$NOTES_FILE" && ! -f "$NOTES_FILE" ]]; then
  echo "Error: notes file not found: $NOTES_FILE"
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

# README carries the version in its footer. It was bumped by hand until it
# silently fell two releases behind, so it rides along with the real bump.
README="$SCRIPT_DIR/README.md"
if [[ -f "$README" ]]; then
  sed -i '' "s/^\*Stampo [0-9][^ ]* — for macOS/\*Stampo $VERSION — for macOS/" "$README"
  git -C "$SCRIPT_DIR" add README.md
fi

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

# Stage only the .app so the DMG window doesn't show xcodebuild's
# export artifacts (DistributionSummary.plist, ExportOptions.plist,
# Packaging.log).
DMG_STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$EXPORT_PATH/Stampo.app" "$DMG_STAGE/"

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
  "$DMG_STAGE/"

rm -rf "$DMG_STAGE"

CHECKSUM=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

# ---------- GitHub Release ----------

echo "▸ Creating GitHub Release..."

if [[ -n "$NOTES_FILE" ]]; then
  CHANGES="$(cat "$NOTES_FILE")"
else
  CHANGES="-"
fi

NOTES="## Stampo $VERSION

> ⚠️ Этот билд не нотаризован, поэтому macOS заблокирует первый запуск.
>
> Запустите Stampo и дайте системе его заблокировать, затем откройте
> **Системные настройки → Конфиденциальность и безопасность**, пролистайте до
> сообщения о заблокированном Stampo и нажмите **«Всё равно открыть»**. Один
> раз — дальше приложение открывается обычным двойным кликом.
>
> Правый клик → «Открыть» здесь не поможет: в macOS 15 Apple убрала этот обход,
> а Stampo требует macOS 15.7 и новее.
>
> Если привычен терминал, установка через Homebrew обходит блокировку сразу:
> \`brew tap git-webuser/stampo https://github.com/git-webuser/Stampo\` и
> \`brew install --cask --no-quarantine stampo\`.

### Что нового
$CHANGES

### Совместимость
- macOS 15.7 и новее
- MacBook с вырезом и обычные дисплеи, включая внешние мониторы

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
