# Stampo

Screenshot, text capture, and color picker for any Mac. The panel lives at the notch (or at the center of the menu bar on screens without one) — no Dock icon, minimal menu bar presence.

---

## What is Stampo

Stampo replaces the usual screenshot workflow with a panel that appears when you hover near the top of your screen. From the panel you can take area, window, or fullscreen screenshots, annotate them in the built-in editor, scan any region for text and QR/barcodes, pick colors, and browse your recent captures in the tray.

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

Stampo needs a single permission to work. You'll be prompted to grant it on first launch, or you can open System Settings manually.

| Permission | Why it's needed |
|---|---|
| **Screen Recording** | Required to take screenshots and sample colors from the screen. |

To grant it: **System Settings → Privacy & Security → Screen Recording** → enable Stampo.

Clicking the notch and global hotkeys work without any permission — they use standard AppKit event monitors and a Carbon hotkey, so there's no Input Monitoring prompt.

## How to use

- **Hover** near the top center of your screen (at the notch) to open the panel.
- **Click a capture mode** to start a screenshot, scan, or color pick.
- **Click the tray icon** (stack icon) to browse recent captures.
- All screenshots are saved to your chosen folder (default: `~/Pictures/Stampo`).

## Scan (text & codes)

Select an area of the screen and Stampo reads it in a single pass: every QR/barcode payload plus all readable text (English and Russian, detected automatically). Everything found is copied to the clipboard in visual order, and each finding is added to the tray as a text entry. Nothing is saved to disk, and code payloads are treated strictly as inert text — never opened, linkified, or fetched. Start it from the capture-mode menu in the panel or with `⌃⌥⌘S`.

## Annotation Editor

Click the post-capture thumbnail (or right-click a screenshot in the tray → **Edit**) to open the built-in editor: lines, arrows, rectangles, ovals, freehand drawing, numbered steps, text labels, circular loupes, and blur/pixelate regions, with full undo/redo (`⌘Z` / `⇧⌘Z`). The second toolbar row shows the settings for the active tool — colors, solid/dashed line styles, three arrow styles (solid, dashed, bold), arrowheads at the start, end, or both endpoints, text formatting (bold, italic, underline, strikethrough, shadow, a light/dark/none background plate, and left/center/right alignment), loupe shape and mode, and controls for line thickness, brush size, text size, marker size, fill opacity (0–100%), magnification, and blur/pixelate intensity. On narrow windows the toolbar buttons collapse from label to icon so nothing wraps.

- **Save** (`⌘S`) always writes a **new file** to your save folder — the original screenshot is never modified — and the result appears in the tray.
- **Copy** (`⌘C`) puts the annotated image on the clipboard at the original pixel resolution.
- Rotate the whole image in 90° steps with the toolbar buttons.
- **Crop** the image: drag a frame with corner/edge handles (or type an exact **W × H** in the toolbar), then **Apply** (**Return**) or **Cancel** (**Esc**). The frame shows a rule-of-thirds grid, nudges with the arrow keys (`⇧` 10 px, `⌥⇧` 50 px), rotates with the image, and stays within the picture; cropping is undoable.
- **Scan** a region: pick the Scan tool, drag over an area, and every QR/barcode payload and all readable text is copied to the clipboard and added to the tray.
- Hover any toolbar control for a tooltip describing it.
- Double-click a text label or step marker to edit it; inside a text label, **Return** commits and **⇧Return** starts a new line. New step markers auto-number from the highest numeric label (labels can be any text, e.g. `1.1` or `4.12`).
- Blur/pixelate always sits beneath the other annotations, so arrows, text, and shapes stay crisp on top of a redacted region.
- The **Loupe** magnifies a region — as an oval or a rounded rectangle, and either in place or as a **callout** (a source marker joined by a connector to a detached magnifier you can position and resize independently). It can reveal either the original image or the redacted result beneath it.
- The **Drawing** tool combines an opaque pen and a wide translucent marker. The separate **Eraser** tool partially removes their strokes without touching shapes, text, or redactions. One drawing or erasing gesture is one undo step.
- Press **⌘D** to duplicate the selected annotation with a **40 × 40 px** offset, or hold **Option** while dragging any annotation to duplicate and move it in one gesture.
- Switch tools from the keyboard: **V** Select, **L** Line, **A** Arrow, **R** Rectangle, **O** Oval, **T** Text, **P** Drawing, **E** Eraser, **B** Blur, **S** Step, and **M** Loupe. Tool shortcuts pause while editing text or typing in a field.
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
| Scan (text & codes) | `⌃⌥⌘S` |
| Pin last screenshot | `⌃⌥⌘P` |
| Collect files | `⌃⌥⌘T` |

Every hotkey is fully customizable in **Settings → Hotkeys** — record a new combination, restore the default, or clear it to disable the action.

## Where screenshots are saved

By default, screenshots are saved to **~/Pictures/Stampo**. You can change the save folder in **Settings → Capture → Save Location**.

File names follow one of four presets, selectable in **Settings → Capture**: compact `Jan·05-14·30·22` (default), ISO `2026-01-05 14-30-22`, numbered `2026-01-05 #1`, or dense `20260105-143022`. The file format is PNG, JPG, or TIFF.

## Tray

The tray shows recent screenshots, color swatches, and scanned text — and it's also a drop shelf for files.

- **Click** a screenshot to open it.
- **Right-click** for options: Edit, Open, Pin to Screen, Show in Finder, Copy, Move to Trash.
- **X button** (on hover) removes the item from the tray — the file is not deleted.
- **Drag** a screenshot out of the tray to copy it anywhere.

### Collect files (drop shelf)

Drop files onto the open tray and they gather into a **stack** — a temporary shelf you fill from several windows, then drag out all at once into a destination folder. Files are grouped by their source folder, so dropping from Downloads and Desktop makes two separate stacks, each labeled with its folder name. Drag a stack out to move everything it holds in one gesture; the stack clears once the files land. The tray keeps references to the originals, never copies, so nothing is duplicated on disk while it sits on the shelf.

Press `⌃⌥⌘T` to open the tray straight into collect mode — the panel pins itself so it survives the mouse-down that starts a drag from another window; press it again to close.

## Pin to Screen

Keep a screenshot floating above all windows while you work — handy for copying data into another app or comparing against a reference. Right-click a screenshot in the tray or on the post-capture thumbnail → **Pin to Screen**, or press `⌃⌥⌘P` to pin the last capture.

Pinned screenshots stay on top of everything, follow you across Spaces, and never steal focus. Drag a pin by its body to move it, resize it from the edges (proportions are kept), and close it with the **X** button, a **double-click**, or **Esc** while hovering it. Right-click a pin for Copy, Edit, Show in Finder, Unpin, or Close All Pins.

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

Stampo runs with the **App Sandbox disabled** (Hardened Runtime is enabled). This is an architectural requirement, not an oversight: the app monitors mouse clicks anywhere on screen (to detect notch clicks), registers global hotkeys, and shells out to the system `screencapture` tool — none of which work inside the sandbox.

How the input pieces actually work — none of them require Input Monitoring, and none read your keystrokes:

- **Notch click** — a pair of standard AppKit mouse monitors (`addGlobalMonitorForEvents` / `addLocalMonitorForEvents`) that observe left mouse-down location only. They cannot modify or block events, and see nothing beyond "was the notch area clicked".
- **Global hotkeys** — registered with Carbon's `RegisterEventHotKey`, so macOS only ever hands Stampo the exact combinations you assigned.
- **Esc to cancel** — a Carbon hotkey active **only while a cancellable surface is on screen** (the panel, the color picker, a capture overlay, or a hovered pin). It captures the single Esc key for that moment and is removed as soon as the surface closes. No other keystrokes are observed at any time.

Screenshots are taken with Apple's official APIs (ScreenCaptureKit and the system `screencapture` tool), saved files are accessed through security-scoped bookmarks, and diagnostic logs contain no captured content, file paths, or precise cursor positions.

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

*Stampo 0.5.3 — for macOS 15.7+*
