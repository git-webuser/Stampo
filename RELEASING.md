# Release Process

> **Current status:** releasing without Developer ID (Apple Developer Program not enrolled).
> App is signed with Apple Development cert (ad-hoc for local use).
> Users will see a Gatekeeper warning on first launch — see [Gatekeeper bypass](#gatekeeper-bypass) below.
>
> ⚠️ **This is a temporary beta workflow — do not use it for a normal public release.**
> Switch to `ExportOptions.DeveloperID.plist` and add notarize + staple steps (see bottom of file) once Developer ID is available.

## Prerequisites

- Xcode 16+
- `create-dmg` installed: `brew install create-dmg`

---

## 1. Update version

In `Stampo.xcodeproj`:
- `MARKETING_VERSION` — e.g. `0.2.0`
- `CURRENT_PROJECT_VERSION` — increment by 1

Commit: `git commit -m "Bump version to 0.2.0"`

---

## 2. Archive

```bash
cd "$(git rev-parse --show-toplevel)"

xcodebuild archive \
  -scheme Stampo \
  -configuration Release \
  -archivePath build/Stampo.xcarchive \
  -destination "generic/platform=macOS"
```

---

## 3. Export

```bash
xcodebuild -exportArchive \
  -archivePath build/Stampo.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist
```

> **Note:** `ExportOptions.plist` uses `method: development` (Apple Development cert, no Developer ID required).
> When Developer ID becomes available, use `ExportOptions.DeveloperID.plist` instead.

Проверить подпись:
```bash
codesign --verify --deep --strict --verbose=2 build/export/Stampo.app
```

---

## 4. Create DMG

Stage only the `.app` first, so the window doesn't show `xcodebuild`'s export
artifacts, and build into a temp directory — **not** straight into `build/`. With
`--background`, create-dmg writes a scratch `rw.*.dmg` next to the output file
and records that file's absolute path in the volume's `.DS_Store`, so building
inside the repo would put your home path and username inside the published DMG.

```bash
VERSION="0.1.0-beta.1"

rm -rf build/dmg-stage && mkdir -p build/dmg-stage
cp -R build/export/Stampo.app build/dmg-stage/

DMG_WORK="$(mktemp -d /private/tmp/stampo-dmg.XXXXXX)"

create-dmg \
  --volname "Stampo" \
  --volicon "build/export/Stampo.app/Contents/Resources/AppIcon.icns" \
  --background "assets/dmg-background.tiff" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 100 \
  --icon "Stampo.app" 200 190 \
  --hide-extension "Stampo.app" \
  --app-drop-link 460 190 \
  "$DMG_WORK/Stampo-${VERSION}.dmg" \
  "build/dmg-stage/"

mv "$DMG_WORK/Stampo-${VERSION}.dmg" "build/Stampo-${VERSION}.dmg"
rm -rf build/dmg-stage "$DMG_WORK"
```

`--volicon` takes the app icon straight out of the bundle, so the volume icon
always matches the app. Drop `--background` if `assets/dmg-background.tiff`
doesn't exist yet. The window geometry above and the background art are composed
against each other — see [assets/README.md](assets/README.md) before changing
either.

---

## 5. SHA256

```bash
VERSION="0.1.0-beta.1"
shasum -a 256 "build/Stampo-${VERSION}.dmg"
```

---

## 6. GitHub Release

1. Push tag: `git tag 0.1.0-beta.1 && git push origin 0.1.0-beta.1`
2. Create release at [github.com/git-webuser/Stampo/releases/new](https://github.com/git-webuser/Stampo/releases/new)
3. Attach `Stampo-0.1.0-beta.1.dmg`
4. Release notes template:

```markdown
## Stampo 0.1.0-beta.1

Public beta for macOS 15.7+.

> ⚠️ This build is not notarized. On first launch macOS will show a warning.
> Right-click → Open to bypass it.

### What's new
- Initial public release

### Known issues
- Hotkeys are not customizable
- Cursor behavior in window picker relies on a private macOS API (may change in future macOS)

### Compatibility
- macOS 15.7 or later
- MacBook with notch display (MacBook Pro 14"/16", MacBook Air M2+)

### Checksum
SHA256: <paste here>
```

5. Mark as **Pre-release**.

---

## 7. Homebrew cask

`release.sh` updates `Casks/stampo.rb` (version + sha256) and pushes it
automatically after creating the GitHub release. If releasing manually,
update those two fields yourself and commit.

Users install with:

```bash
brew tap git-webuser/stampo https://github.com/git-webuser/Stampo
brew install --cask --no-quarantine stampo
```

---

## Gatekeeper bypass

Пользователи увидят: *"Stampo can't be opened because Apple cannot check it for malicious software."*

Два способа:

**Способ 1 — right-click → Open** (рекомендуется для пользователей)
- Правый клик по `Stampo.app` в Finder → Open → Open

**Способ 2 — снять карантин в терминале**
```bash
xattr -cr /Applications/Stampo.app
```

Написать в README чётко что одно из этих действий нужно при первом запуске.

---

## Когда появится Developer ID — добавить между шагами 4 и 5

```bash
VERSION="0.1.0-beta.1"

# Настроить один раз:
# xcrun notarytool store-credentials "notary-profile" \
#   --apple-id "your@apple.id" \
#   --team-id C4KBH3KJS5 \
#   --password "app-specific-password"

xcrun notarytool submit "build/Stampo-${VERSION}.dmg" \
  --keychain-profile "notary-profile" \
  --wait

xcrun stapler staple "build/Stampo-${VERSION}.dmg"

spctl --assess --type open --context context:primary-signature -v "build/Stampo-${VERSION}.dmg"
```
