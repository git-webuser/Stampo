#!/usr/bin/env node
// Renders chosen frames of the clips as PNGs, from one bundle and one browser,
// and tiles each clip's frames into out/stills/<Clip>.png.
//
//   npm run stills                    every clip's key frames
//   npm run stills -- Scan            one clip's key frames
//   npm run stills -- Scan 40 41 42   just these frames of it
//
// Each clip's list starts at frame 0 and ends on its last frame, so the
// sheet shows whether the loop closes.

import { bundle } from "@remotion/bundler";
import { openBrowser, renderStill, selectComposition } from "@remotion/renderer";
import { execFileSync } from "node:child_process";
import { mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));

const KEY_FRAMES = {
  Capture: [0, 24, 40, 52, 100, 116, 136, 167],
  Editor: [8, 28, 44, 70, 104, 146, 174, 199],
  Scan: [0, 26, 46, 76, 92, 106, 126, 149],
  Archive: [0, 30, 46, 100, 116, 150, 198, 239],
};

const words = process.argv.slice(2);
const named = words.filter((w) => w in KEY_FRAMES);
const numbers = words.map(Number).filter((n) => !Number.isNaN(n));
const clips = named.length ? named : Object.keys(KEY_FRAMES);

const serveUrl = await bundle({ entryPoint: join(root, "src", "index.ts") });
const browser = await openBrowser("chrome");
for (const id of clips) {
  const outDir = join(root, "out", "stills", id);
  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });
  const composition = await selectComposition({ serveUrl, id, puppeteerInstance: browser });
  const frames = numbers.length ? numbers : KEY_FRAMES[id];
  for (const frame of frames) {
    const output = join(outDir, `f${String(frame).padStart(3, "0")}.png`);
    await renderStill({ composition, serveUrl, frame, output, puppeteerInstance: browser });
  }
  const cols = Math.min(4, frames.length);
  const rows = Math.ceil(frames.length / cols);
  execFileSync("ffmpeg", [
    "-v", "error", "-y", "-pattern_type", "glob", "-i", join(outDir, "f*.png"),
    "-vf", `scale=800:-1,tile=${cols}x${rows}:padding=6:color=0x888888`,
    "-frames:v", "1", join(root, "out", "stills", `${id}.png`),
  ]);
  console.log(`${id}: ${frames.join(" ")}`);
}
await browser.close({ silent: true });
