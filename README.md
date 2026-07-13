# Stampo

Screenshot, text capture, and color picker for any Mac. The panel lives at the notch (or at the center of the menu bar on screens without one) — no Dock icon, minimal menu bar presence.

---

## What is Stampo

Stampo replaces the usual screenshot workflow with a panel that appears when you hover near the top of your screen. From the panel you can take area, window, or fullscreen screenshots, annotate them in the built-in editor, capture text from the screen (OCR), pick colors, and browse your recent captures in the tray.

## Requirements

- macOS 15.7 or later

> **Note:** Stampo is designed around the notch, but works on any Mac. On screens without a notch the panel is drawn at the top center of the menu bar; its style and size are configurable in **Settings → General**.

## Installation

### Homebrew (recommended)

```bash
brew tap git-webuser/stampo https://github.com/git-webuser/Stampo
brew install --cask --no-quarantine stampo
```

The `--no-quarantine` flag skips the Gatekeeper warning for this
not-yet-notarized build. Update later with `brew upgrade --cask stampo`.

### Manual

1. Download the latest `Stampo-<version>.dmg` from the [Releases](https://github.com/git-webuser/Stampo/releases) page.
2. Open the DMG and drag **Stampo.app** to your **Applications** folder.
3. Open Stampo from Applications.

**First launch:** macOS will show *"Stampo can't be opened because Apple cannot check it for malicious software."* This is expected — the app is not yet notarized.

To open it: right-click **Stampo.app** in Finder → **Open** → **Open**. You only need to do this once. On macOS 15 you may instead need to allow it via **System Settings → Privacy & Security → Open Anyway** after the first blocked launch.

## Permissions

Stampo requires two permissions to work correctly. You will be prompted to grant them on first use, or you can open System Settings manually.

| Permission | Why it's needed |
|---|---|
| **Screen Recording** | Required to take screenshots and sample colors from the screen. |
| **Input Monitoring** | Required to detect clicks in the notch area and respond to global hotkeys. |

To grant permissions: **System Settings → Privacy & Security → Screen Recording / Input Monitoring** → enable Stampo.

## How to use

- **Hover** near the top center of your screen (at the notch) to open the panel.
- **Click a capture mode** to start a screenshot, text capture, or color pick.
- **Click the tray icon** (stack icon) to browse recent captures.
- All screenshots are saved to your chosen folder (default: `~/Downloads`).

## Capture Text (OCR)

Select an area of the screen and Stampo recognizes the text in it (English and Russian, detected automatically) and copies it to the clipboard. Nothing is saved to disk. Start it from the capture-mode menu in the panel or with `⌃⌥⌘T`.

## Annotation Editor

Click the post-capture thumbnail (or right-click a screenshot in the tray → **Edit**) to open the built-in editor: lines, arrows, rectangles, ovals, freehand drawing, numbered steps, text labels, and blur/pixelate regions, with full undo/redo (`⌘Z` / `⇧⌘Z`). The second toolbar row shows the settings for the active tool — colors, solid/dashed line styles, three arrow styles (solid, dashed, bold), arrowheads at the start, end, or both endpoints, text formatting (bold, italic, underline, strikethrough, shadow, and a light/dark/none background plate), and sliders for line thickness, brush size, text size, marker size, fill opacity (0–100%), and blur/pixelate intensity. On narrow windows the toolbar buttons collapse from label to icon so nothing wraps.

- **Save** (`⌘S`) always writes a **new file** to your save folder — the original screenshot is never modified — and the result appears in the tray.
- **Copy** (`⌘C`) puts the annotated image on the clipboard at the original pixel resolution.
- Rotate the whole image in 90° steps with the toolbar buttons.
- **Crop** the image: drag a frame with corner/edge handles (or type an exact **W × H** in the toolbar), then **Apply** (**Return**) or **Cancel** (**Esc**). The frame shows a rule-of-thirds grid, nudges with the arrow keys (`⇧` 10 px, `⌥⇧` 50 px), rotates with the image, and stays within the picture; cropping is undoable.
- **Recognize text** from a region: pick the text-recognition tool, drag over an area, and its text is copied to the clipboard.
- Hover any toolbar control for a tooltip describing it.
- Double-click a text label or step marker to edit it; inside a text label, **Return** commits and **⇧Return** starts a new line. New step markers auto-number from the highest numeric label (labels can be any text, e.g. `1.1` or `4.12`).
- Blur/pixelate always sits beneath the other annotations, so arrows, text, and shapes stay crisp on top of a redacted region.
- The **Drawing** tool combines an opaque pen, a wide translucent marker, and a partial eraser that removes pen/marker strokes without touching shapes, text, or redactions. One drawing or erasing gesture is one undo step.
- Press **⌘D** to duplicate the selected annotation with a **40 × 40 px** offset, or hold **Option** while dragging any annotation to duplicate and move it in one gesture.
- Switch tools from the keyboard: **V** Select, **L** Line, **A** Arrow, **R** Rectangle, **O** Oval, **T** Text, **P** Drawing, **B** Blur, and **S** Step. Tool shortcuts pause while editing text or typing in a field.
- Format the selected or inline-edited text with **⌘B** Bold, **⌘I** Italic, **⌘U** Underline, **⇧⌘X** Strikethrough, and **⇧⌘H** Shadow. With no selection, these shortcuts configure the next text label.
- Press **Delete** / **Backspace** to remove the selected annotation. **Esc** cancels the active mode or returns the active tool to the cursor; use **⌘W** to close the editor.
- Hold **Shift** to snap lines and arrows to 45° or draw square/circular shapes; use arrow keys to nudge the selected annotation by 1 px (`⇧`: 10 px, `⌥⇧`: 50 px).
- Pinch to zoom, and pan a zoomed image by dragging an empty area (or holding **Space** while dragging); use `⌘−`, `⌘+`, or `⌘0` to zoom out, zoom in, or fit the image.
- Prefer the old behavior? Set **Settings → General → On thumbnail click** to *Open preview*.

## Hotkeys

| Action | Default shortcut |
|---|---|
| Toggle panel | `⌃⌥⌘N` |
| Selection screenshot | `⌃⌥⌘R` |
| Fullscreen screenshot | `⌃⌥⌘B` |
| Window screenshot | `⌃⌥⌘G` |
| Pick color | `⌃⌥⌘C` |
| Capture text (OCR) | `⌃⌥⌘T` |

Every hotkey is fully customizable in **Settings → Hotkeys** — record a new combination, restore the default, or clear it to disable the action.

## Where screenshots are saved

By default, screenshots are saved to **~/Downloads**. You can change the save folder in **Settings → Capture → Save Location**.

File names follow one of four presets, selectable in **Settings → Capture**: compact `Jan·05-14·30·22` (default), ISO `2026-01-05 14-30-22`, numbered `2026-01-05 #1`, or dense `20260105-143022`. The file format is PNG, JPG, or TIFF.

## Tray

The tray shows recent screenshots and color swatches.

- **Click** a screenshot to open it.
- **Right-click** for options: Edit, Open, Show in Finder, Copy, Move to Trash.
- **X button** (on hover) removes the item from the tray — the file is not deleted.
- **Drag** a screenshot out of the tray to copy it anywhere.

## Known Limitations

- **Window screenshot** without a timer uses the frontmost window at the moment of capture. If another window becomes active during the hotkey press, it may be captured instead.
- **Cursor behavior** in the capture overlays relies on a private macOS API (`CGSSetConnectionProperty`), resolved at runtime. If a future macOS removes it, Stampo keeps working — only the cursor override while another app is frontmost is skipped.

## Privacy & Security

Stampo does not upload screenshots, sampled colors, or any other data.

- **One optional network request**: once a day Stampo asks the GitHub API
  for the latest release version to offer an update notification. It sends
  nothing beyond a standard HTTPS request and can be turned off in
  **Settings → General → Updates**. There are no other network requests.
- No analytics or telemetry.
- No crash reporting.
- All captures stay on your Mac.

### Why Stampo is not sandboxed

Stampo runs with the **App Sandbox disabled** (Hardened Runtime is enabled). This is an architectural requirement, not an oversight: detecting clicks on the notch area and responding to global hotkeys rely on a `CGEventTap`, which is incompatible with the sandbox.

What the event taps actually do:

- **Notch click** — a *listen-only* tap that observes left mouse clicks. It cannot modify, block, or record anything beyond "was the notch area clicked".
- **Esc during color picking** — a *listen-only* tap active **only while the color picker is running**, observing a single key (Esc) to cancel the session. It is removed the moment picking ends. No other keystrokes are observed at any time.

Stampo never reads keyboard input outside of these scoped, user-initiated interactions. Screenshots are taken with Apple's official APIs (ScreenCaptureKit and the system `screencapture` tool), saved files are accessed through security-scoped bookmarks, and diagnostic logs contain no captured content, file paths, or precise cursor positions.

## Uninstall

1. Quit Stampo.
2. Move **Stampo.app** from Applications to Trash.
3. To remove all settings and saved data:

```
~/Library/Preferences/com.hex000.Stampo.plist
~/Library/Application Support/Stampo
```

## License

MIT License. See [LICENSE](LICENSE).

---

*Stampo 0.5.0 — for macOS 15.7+*
