# Stampo

Screenshot and color picker for MacBooks with a notch. The panel lives at the notch — no Dock icon, minimal menu bar presence.

---

## What is Stampo

Stampo replaces the usual screenshot workflow with a panel that appears when you hover near the top of your screen. From the panel you can take area, window, or fullscreen screenshots, pick colors from the screen, and browse your recent captures in the tray.

## Requirements

- macOS 15.7 or later
- MacBook with a built-in notch display (MacBook Pro 14" or 16", MacBook Air M2 or later)

> **Note:** Stampo is designed for notch displays. It will launch on non-notch Macs but the panel positioning may not be ideal.

## Installation

1. Download `Stampo-0.1.0-beta.1.dmg` from the [Releases](https://github.com/git-webuser/Stampo/releases) page.
2. Open the DMG and drag **Stampo.app** to your **Applications** folder.
3. Open Stampo from Applications.

**First launch:** macOS will show *"Stampo can't be opened because Apple cannot check it for malicious software."* This is expected — the app is not yet notarized.

To open it: right-click **Stampo.app** in Finder → **Open** → **Open**. You only need to do this once.

## Permissions

Stampo requires two permissions to work correctly. You will be prompted to grant them on first use, or you can open System Settings manually.

| Permission | Why it's needed |
|---|---|
| **Screen Recording** | Required to take screenshots and sample colors from the screen. |
| **Input Monitoring** | Required to detect clicks in the notch area and respond to global hotkeys. |

To grant permissions: **System Settings → Privacy & Security → Screen Recording / Input Monitoring** → enable Stampo.

## How to use

- **Hover** near the top center of your screen (at the notch) to open the panel.
- **Click a capture mode** to start a screenshot or color pick.
- **Click the tray icon** (stack icon) to browse recent captures.
- All screenshots are saved to your chosen folder (default: `~/Downloads`).

## Hotkeys

| Action | Shortcut |
|---|---|
| Toggle panel | `⌃⌥⌘N` |
| Selection screenshot | `⌃⌥⌘R` |
| Fullscreen screenshot | `⌃⌥⌘B` |
| Window screenshot | `⌃⌥⌘G` |
| Pick color | `⌃⌥⌘C` |

Hotkeys can be enabled or disabled individually in **Settings → Hotkeys**.

## Where screenshots are saved

By default, screenshots are saved to **~/Downloads**. You can change the save folder in **Settings → Capture → Save Location**.

File names follow the format: `Stampo YYYY-MM-DD at HH.MM.SS.png` (configurable in Settings).

## Tray

The tray shows recent screenshots and color swatches.

- **Click** a screenshot to open it.
- **Right-click** for options: Open, Show in Finder, Copy, Move to Trash.
- **X button** (on hover) removes the item from the tray — the file is not deleted.
- **Drag** a screenshot out of the tray to copy it anywhere.

## Known Limitations

- **Notch display required** — the panel is designed around the notch area. On non-notch Macs the experience is degraded.
- **Hotkeys are fixed** — key combinations cannot currently be customized.
- **Window screenshot** without a timer uses the frontmost window at the moment of capture. If another window becomes active during the hotkey press, it may be captured instead.
- **Cursor behavior** in the window picker overlay relies on a private macOS API (`CGSSetConnectionProperty`). This works on macOS 14–15 but may change in a future release.

## Privacy

Stampo does not upload screenshots, sampled colors, or any other data.

- No network requests.
- No analytics or telemetry.
- No crash reporting.
- All captures stay on your Mac.

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

*Stampo 0.2.0-beta.1 — Public beta for macOS 15.7+*
