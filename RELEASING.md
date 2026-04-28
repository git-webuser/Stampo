# Release Process

> **Current status:** releasing without Developer ID (Apple Developer Program not enrolled).
> App is signed with Apple Development cert (ad-hoc for local use).
> Users will see a Gatekeeper warning on first launch — see [Gatekeeper bypass](#gatekeeper-bypass) below.
>
> When Developer ID is available: add notarize + staple steps between steps 4 and 5.

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
cd /Users/air/Documents/xcode/Stampo

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

Проверить подпись:
```bash
codesign --verify --deep --strict --verbose=2 build/export/Stampo.app
```

---

## 4. Create DMG

```bash
VERSION="0.1.0-beta.1"

create-dmg \
  --volname "Stampo" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 100 \
  --icon "Stampo.app" 200 190 \
  --hide-extension "Stampo.app" \
  --app-drop-link 460 190 \
  "build/Stampo-${VERSION}.dmg" \
  "build/export/"
```

---

## 5. SHA256

```bash
VERSION="0.1.0-beta.1"
shasum -a 256 "build/Stampo-${VERSION}.dmg"
```

---

## 6. GitHub Release

1. Push tag: `git tag 0.1.0-beta.1 && git push origin 0.1.0-beta.1`
2. Create release at [github.com/hex000/Stampo/releases/new](https://github.com/hex000/Stampo/releases/new)
3. Attach `Stampo-0.1.0-beta.1.dmg`
4. Release notes template:

```markdown
## Stampo 0.1.0-beta.1

Public beta for macOS 15+.

> ⚠️ This build is not notarized. On first launch macOS will show a warning.
> Right-click → Open to bypass it.

### What's new
- Initial public release

### Known issues
- Hotkeys are not customizable
- Cursor behavior in window picker relies on a private macOS API (may change in future macOS)

### Compatibility
- macOS 15 or later
- MacBook with notch display (MacBook Pro 14"/16", MacBook Air M2+)

### Checksum
SHA256: <paste here>
```

5. Mark as **Pre-release**.

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
