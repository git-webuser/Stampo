# The Stampo site

The landing page at <https://git-webuser.github.io/Stampo/>. Plain HTML and
CSS, no generator and no toolchain.

## How it gets published

`.github/workflows/pages.yml` runs `Scripts/build-site.sh`, which puts this
folder together with what it borrows from the rest of the repository, and
deploys the result to GitHub Pages. It runs on every push to `main` that
touches the page, the artwork, the clips or the cask; a pull request that
touches the page gets a build without a deploy.

Pages has to be set to **Settings → Pages → Build and deployment → Source:
GitHub Actions** once. Not a branch: the page is assembled, not stored.

## Files

| file | what it is |
| --- | --- |
| `index.html` | the whole page, both languages |
| `style.css` | all of the styling |
| `icon.png` | the app icon, 192 px — favicon, touch icon and the mark in the top bar |

What the build adds, so it is never copied here:

| on the site | from |
| --- | --- |
| `assets/banner.png`, `assets/social-preview.png` | `assets/brand/` |
| `assets/clip-*.mp4` | `assets/screenshots/`, made by `npm run mp4` in `video/` |
| the version number (`@VERSION@` in `index.html`) | `Casks/stampo.rb` |

The version comes from the cask rather than the Xcode project because
`release.sh` commits the cask only after the DMG is up, so the page never
names a version that cannot be downloaded yet. The download links go to
`/releases`, not `/releases/latest`: every release is published as a
pre-release, and GitHub's "latest" skips those, so that URL is a 404.

`icon.png` is the one thing to remember by hand — re-render it when
`Stampo/AppIcon.icon` changes, from the generation-26 renderer that the
shipped `.icns` uses:

```bash
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  Stampo/AppIcon.icon --export-image --output-file site/icon.png --platform macOS \
  --rendition Default --width 192 --height 192 --scale 1 --design-generation 26
```

It comes out as 16-bit PNG at three times the size; `ffmpeg -i site/icon.png
-pix_fmt rgba icon8.png` brings it down to 8 bits.

## Previewing

```bash
bash Scripts/build-site.sh                     # -> build/site
python3 -m http.server 8000 --directory build/site
```

then open <http://localhost:8000>.

## The two languages

Both live in the same HTML. Every piece of text exists twice, as
`<… lang="en">` and `<… lang="ru">`, and a hidden checkbox at the top of
`<body>` hides one set through CSS. The switch therefore works with
JavaScript off; the inline script only picks the starting language from the
browser, remembers the reader's choice, and swaps the window title.

**So an edit to one language is only half an edit.** A new paragraph is two
paragraphs, side by side.

Russian names of actions, menus and settings come from
`Stampo/Localizable.xcstrings` — the app's own wording, not a fresh
translation: «Снять», «Сканер», «Оформление», «Чёлка», **Настройки →
Команды**. Look up how the app already says a thing before writing it.

## The clips

Each one is a `<video autoplay muted loop playsinline>`, so they play without
JavaScript. With it, a clip starts from its first frame the first time it
scrolls into view and pauses while it is out of view. With Reduce Motion on,
nothing starts by itself: each clip rests on the frame named in its
`data-still` (seconds) — chosen as the one that tells the clip's story — and
gets the player's controls.

Change a clip in `video/`, then run both `npm run webp` (the README) and
`npm run mp4` (here).
