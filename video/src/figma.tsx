import React, { useEffect, useState } from "react";
import { continueRender, delayRender, staticFile } from "remotion";

// public/onboarding-lite.svg is the onboarding exactly as Figma exported it,
// CSS keyframes and all. What this clip takes from it is the scene at rest —
// laptop, screen, dock, base — so the animation is stripped, and so are the
// layers the clip draws and moves itself (panel, window, cursors, thumbnail).

// Laptop-space geometry, measured from the export with getBoundingClientRect.
export const SCREEN = { x: 247, y: 147, w: 704, h: 457 };
// The notch's centre, in screen-local coordinates.
export const NOTCH_X = 352;

const HIDDEN = [
  "HIde_Lite_bg_0", // the white page, so the hare can sit behind the lid
  "Pointers",
  "Pointers_2",
  "Pointers_3",
  "Frame_1000001170", // the flash behind the thumbnail
  "Frame_1000001168", // the dimmed selection
  "Frame_1000001142", // the thumbnail
  "Frame_1000001165", // the window
  "Rectangle_12251", // the notch, which the clip widens into the panel
  "Button",
  "Frame",
  "Frame_2",
];

// Injected into the page as markup, this export renders a black screen in
// Chrome (the screen's layers are in the DOM but never paint), while the same
// markup as a standalone SVG document renders correctly. So it goes in as an
// image, with the hidden layers switched off by a style inside it.
const clean = (src: string) =>
  src
    .replace(/<style>[\s\S]*?<\/style>/, `<style>${HIDDEN.map((id) => `#${id}`).join(",")}{display:none}</style>`)
    .replace(/<animate\b[^>]*\/>/g, "")
    // Figma's background blurs; both belong to layers hidden above.
    .replace(/<foreignObject\b[\s\S]*?<\/foreignObject>/g, "");

let cached: string | null = null;

const useFigma = () => {
  const [url, setUrl] = useState(cached);
  const [handle] = useState(() => delayRender("Loading the onboarding SVG"));
  useEffect(() => {
    const ready = (u: string) => {
      // Hold the frame until the browser has actually decoded the image.
      const img = new Image();
      img.src = u;
      img.decode().then(() => continueRender(handle));
    };
    if (cached) {
      ready(cached);
      return;
    }
    fetch(staticFile("onboarding-lite.svg"))
      .then((r) => r.text())
      .then((text) => {
        cached = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(clean(text))}`;
        setUrl(cached);
        ready(cached);
      });
  }, [handle]);
  return url;
};

export const Laptop: React.FC = () => {
  const url = useFigma();
  if (!url) return null;
  return <image href={url} x={0} y={0} width={1200} height={800} />;
};
