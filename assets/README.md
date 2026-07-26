# DMG assets

Artwork for the disk image `release.sh` publishes. Nothing here is compiled into
the app — keep it out of `Stampo/`, which is a file-system-synchronized Xcode
group that copies every file it contains into `Stampo.app` as a resource.

## Volume icon

There is no file for it. `release.sh` passes `create-dmg --volicon` the app's own
`Contents/Resources/AppIcon.icns` out of the bundle Xcode just built from
`Stampo/AppIcon.icon`, so the mounted volume always carries the current app icon
with nothing to keep in sync here.

## Window background

`release.sh` uses `assets/dmg-background.tiff` if it exists, and leaves the
window plain white if it doesn't.

### Canvas

`dmg-background-template.svg` in this folder is the whole spec below as guides —
import it into Figma and draw against it. Its layers (`zone-safe-0-316`,
`icon-stampo-app-200-190`, `finder-label-band-253-266`, …) are meant to be
hidden before export.

The DMG window is 660 × 400 pt with 100 pt icons at `200,190` (Stampo.app) and
`460,190` (the Applications drop link) — centres, measured in points from the
top-left of the image. Finder draws the two icon names across 253–266 pt,
centred under each icon.

Export one 4x PNG — **2640 × 1600** — over `dmg-background@4x.png`, then:

```
./assets/make-background.sh
```

That derives the 660 × 400 and 1320 × 800 representations (exact 1/4 and 1/2 of
the master, so no pixel is invented) and writes `dmg-background.tiff`. Commit the
master and the TIFF together.

A single-resolution PNG also works as a background, but it is drawn at 1x and
looks soft next to the crisp icons on every Retina Mac. The two-representation
TIFF is what makes the background sharp; Finder picks the 1320 × 800
representation on Retina displays (measured, not assumed).

### The master is the PNG, not the SVG

`dmg-background.svg` is kept as the editable layout source, but it is **not** what
ships and it is not a faithful copy of it: Figma's SVG export drops the
checkerboard texture and leaves that shape as flat `#0D6FFF`. Anything that needs
to match the real background must come from `dmg-background@4x.png`.

### Safe area — the bottom is cropped

The image is anchored to the top-left of the icon view and clipped, not scaled.
The window's 400 pt includes 28 pt of title bar, and Finder's optional path and
status bars eat into it further, so the visible height depends on settings the
downloader controls:

| downloader's Finder                  | visible height |
| ------------------------------------ | -------------- |
| default (path bar and status bar off) | 372 pt         |
| path bar on                           | 344 pt         |
| path bar and status bar on            | ~316 pt        |

So: compose everything that matters inside the **top 316 pt**, treat 316–372 pt
as decoration that may or may not be seen, and expect the bottom 28 pt to never
appear. The icons and their labels sit at 140–265 pt, comfortably inside that.

### Appearance

A DMG background does not adapt to light and dark mode — `.DS_Store` has room
for exactly one background image, so a light image stays light for dark-mode
users. Make it appearance-neutral.
