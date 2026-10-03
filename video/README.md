# video

The four short clips in the README — **Capture**, **Editor**, **Scan**,
**Archive** — made with [Remotion](https://remotion.dev) on top of the
onboarding's own Figma layers.

A standalone Node project. Xcode's file-system-synchronized groups cover
`Stampo/` and `StampoTests/` only, so nothing here reaches the app, and
`release.sh` does not look at it.

## The rules

- **The app's UI looks as it does in the app.** The panel's outline and glyphs
  come from `figma/panel.svg`; the archive is laid out as measured on
  the archive screenshot the README carried until 384d92e
  (`git show 384d92e:assets/screenshots/panel-archive.png`); the colour HUD follows
  `ColorPickerHUD.swift` (3 × 3 magnifier of 14 pt cells, format and value,
  "Copied" with a check). Glyphs the panel file lacks are the app's own SF
  Symbols at the size and weight the app uses them.
- **Words become lines.** Wherever the app shows text — the Capture button, the
  format menu, the HUD's value — a line stands in, as in the onboarding.
- **The rest is the onboarding's schematic world**: its laptop, screen, dock and
  window, unchanged.
- **Colour belongs to Stampo.** The scene stays grey; the brand's pixel checker,
  doodles, glove and hare (from `assets/dmg-background.svg`) appear where
  Stampo acts. Things thrown into the notch are the clips' own shorthand for
  "went to the archive", not an app animation.
- **No dark versions, no words** — so no theme or language matrix.

## Usage

```bash
npm install
npm run studio    # Remotion Studio, to scrub the clips
npm run stills    # key frames of every clip -> out/stills/<Clip>.png
npm run webp      # render and encode -> ../assets/screenshots/clip-*.webp
npm run symbols   # re-export the SF Symbols (only if they change)
```

`npm run stills -- Scan 40 41 42` renders just those frames of one clip. Each
clip's sheet starts on frame 0 and ends on its last, so it shows whether the
loop closes.

## Where things come from

| what | where |
| --- | --- |
| laptop, screen, dock, base | `public/onboarding-lite.svg` — the onboarding as Figma exported it, CSS keyframes stripped at load |
| panel outline and glyphs | `figma/panel.svg` → `src/brand/panel.ts` |
| archive header, text-tile and HUD symbols | `scripts/export-symbols.swift` → `public/symbols/*.png`, `src/brand/symbols.json` |
| checker colours | sampled from `assets/dmg-background@4x.png` (`src/brand/pixels.tsx`) |
| glove, hare, star, arrows, loops | `assets/dmg-background.svg` → `src/brand/doodles.ts` |

## Things that bit

- **The Figma export renders a black screen when injected as markup.** All its
  layers are in the DOM and none of the screen paints. The same markup as a
  standalone document is fine, so `src/figma.tsx` hands it to an SVG `<image>`
  as a data URL and switches off the layers the clips draw themselves with a
  style inside it.
- **The hard-edged checker is the most expensive thing to encode.** As the
  Decor page it made that stretch twice as heavy as anything else; as a picture
  under a zooming camera it doubled the Archive clip. Both became the smooth
  page gradient. Keep the checker to small things: rays, the scan beam.
- **Clip lengths are multiples of 6 frames.** The clips run at 30 fps and the
  WebP at 25; anything else leaves a stray frame at the loop's seam.
- **SVG `<image>`s are not waited for by the renderer.** The SF Symbols are
  preloaded with `delayRender` (`usePreloadSymbols`), or early frames come out
  without them.
- **A thick border on a rounded rect needs a smaller radius than the fill**
  (radius less half the stroke), or the fill shows outside it at the corners —
  white flecks on the thumbnail's corners until that was fixed.
