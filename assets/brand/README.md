# Brand artwork

The two images that are not screenshots. Both are drawn in Figma; export over
the file and commit it.

## `banner.png` — 1624 × 400

The title plate at the top of `README.md`, in place of a `# Stampo` heading.
Shown at half its pixel size, so it stays crisp on Retina:

```html
<img src="assets/brand/banner.png" alt="Stampo — screenshots, scan, colors" width="812">
```

The artwork sits on an opaque white plate rather than a transparent background:
one file then reads the same on GitHub's light and dark themes, with no
`<picture>` and two variants to keep in sync.

**Figma exports transparent by default, and this file has arrived that way
before.** Nothing looks wrong locally — the Finder preview and every light-theme
viewer put white behind it — but the wordmark is near-black, so on GitHub's dark
theme it goes with the background. After exporting, check:

```bash
sips -g hasAlpha assets/brand/banner.png   # must say: no
```

## `social-preview.png` — 2560 × 1280

The Open Graph card: what [topic pages](https://github.com/topics/screenshot),
search results, and links shared in chat apps show.

**It is not picked up from the repository.** GitHub stores it per repository and
there is no API for it, so every change has to be uploaded by hand:

**Settings → General → Social preview → Upload an image**

The file is committed anyway, so the next upload starts from the last thing
published rather than from scratch. Keep it under **1 MB** — that is the upload
limit.

### Safe area

1280 × 640 (2:1) is the ratio GitHub asks for and the one its own cards use, so
nothing is cropped there. The crop happens elsewhere:

| where | what it does |
| --- | --- |
| GitHub cards, Slack, Discord, Telegram | whole image, no crop — but as little as 360 pt wide |
| Facebook, LinkedIn, X `summary_large_image` | 1.91:1 — trims **57 px off each side** at 2x |

So the margins that matter are horizontal: keep anything that has to survive
**128 px** clear of the left and right edges. Vertically nothing is cropped;
~80 px is enough to stay out of a card's rounded corners. And check the artwork
at ~420 px wide — at that size a tagline still reads and toolbar icons do not.
