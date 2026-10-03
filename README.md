<img src="assets/brand/banner.png" alt="Stampo — screenshots, scan, colors" width="812">

Screenshot, scan, and color picker for macOS, living in the notch. No Dock icon; on a Mac without a notch the panel sits at the top of the menu bar.

## What is Stampo

### Capture

<img src="assets/screenshots/clip-capture.webp" alt="A click on the notch opens the panel and Capture is pressed; a window is framed, the shot drops into the corner as a thumbnail and goes on into the archive" width="812">

Click the notch: an area, a window or the whole screen.

### Mark up

<img src="assets/screenshots/clip-editor.webp" alt="A thumbnail opens in the editor; an arrow, a star and a loop are drawn on the screenshot, Decor sets it on a gradient page with margins, and the result goes into the archive" width="812">

Arrows, shapes, text, blur — and Decor sets the shot on a page.

### Scan and translate

<img src="assets/screenshots/clip-scan.webp" alt="A frame is drawn over a window of text, a beam reads it line by line, the lines turn over into their translation, and a copy goes into the archive" width="812">

Text and QR codes from anywhere on screen, translated on your Mac.

### Pick colors, keep everything

<img src="assets/screenshots/clip-archive.webp" alt="A color is picked off a picture, the picker's magnifier beside the pointer; the panel then opens the archive — the color just picked, the scanned text and the decorated screenshot, newest first" width="812">

Colors, scans and shots wait in the archive at the notch.

## Installation

macOS 15.7 or later.

```bash
brew tap git-webuser/stampo https://github.com/git-webuser/Stampo
brew install --cask --no-quarantine stampo
```

<details>
<summary>Or download the DMG</summary>

1. Download `Stampo-<version>.dmg` from [Releases](https://github.com/git-webuser/Stampo/releases) and drag **Stampo.app** to Applications.
2. Open it. macOS blocks the first launch: the app isn't notarized yet.
3. Go to **System Settings → Privacy & Security**, click **Open Anyway** and confirm.

</details>

## Permissions

Only **Screen Recording**, asked for on first launch. The notch click and the hotkeys need none.

## Hotkeys

| Action | Shortcut |
|---|---|
| Toggle panel | `⌃⌥⌘N` |
| Selection screenshot | `⌃⌥⌘R` |
| Fullscreen screenshot | `⌃⌥⌘B` |
| Window screenshot | `⌃⌥⌘G` |
| Pick color | `⌃⌥⌘C` |
| Scan (text & codes) | `⌃⌥⌘S` |
| Translate clipboard | `⌃⌥⌘T` |
| Pin latest capture | `⌃⌥⌘L` |
| Pin panel (collect files) | `⌃⌥⌘P` |
| Share last item | `⌃⌥⌘D` |

Change any of them in **Settings → Hotkeys**.

## More

- [User guide](MANUAL.md) — every feature in detail
- [Privacy & security](SECURITY.md)

---

*Stampo 0.9.2 — for macOS 15.7+*
