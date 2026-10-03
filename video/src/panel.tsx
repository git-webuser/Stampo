import React, { useEffect, useState } from "react";
import { continueRender, delayRender, staticFile } from "remotion";
import { NOTCH_X } from "./figma";
import { CAPTURE_BUTTON, GLYPH_AT, PANEL_SVG, panelGlyphs } from "./brand/panel";
import symbols from "./brand/symbols.json";
import { Artwork, PAGE, PICKED, Shot, SHOT } from "./scene";

// The app's own UI, as it looks in the app — the panel, the archive, the
// colour picker's HUD — laid out in points and scaled so the panel's 28 pt is
// the notch's 15 screen units. Where the app shows words, a line stands in.

export const PT = 15 / PANEL_SVG.h;
export const PANEL_OPEN = PANEL_SVG.body * PT;
const INK = "#1A1919";

// Screen x of a point on the panel, from its x in panel.svg.
export const panelX = (svgX: number) => NOTCH_X + (svgX - PANEL_SVG.centre) * PT;
export const GLYPH_Y = 14 * PT;

// The outline grows out of the notch: flares at the top, rounded at the foot.
const outline = (w: number, h: number) => {
  const f = PANEL_SVG.flare * PT;
  const r = Math.min(PANEL_SVG.radius * PT, h / 2, w / 2);
  const x0 = -w / 2;
  const x1 = w / 2;
  return [
    `M ${x0 - f} -2 L ${x0 - f} 0 Q ${x0} 0 ${x0} ${f}`,
    `L ${x0} ${h - r} Q ${x0} ${h} ${x0 + r} ${h}`,
    `L ${x1 - r} ${h} Q ${x1} ${h} ${x1} ${h - r}`,
    `L ${x1} ${f} Q ${x1} 0 ${x1 + f} 0 L ${x1 + f} -2 Z`,
  ].join(" ");
};

type SymbolName = keyof typeof symbols;

// SVG <image>s are not waited for by the renderer: hold the first frame until
// every symbol is decoded, after which they paint from cache.
let symbolsReady = false;
export const usePreloadSymbols = () => {
  const [handle] = useState(() => (symbolsReady ? null : delayRender("Loading SF Symbols")));
  useEffect(() => {
    if (handle === null) return;
    Promise.all(
      Object.keys(symbols).map((name) => {
        const img = new Image();
        img.src = staticFile(`symbols/${name}.png`);
        return img.decode();
      })
    ).then(() => {
      symbolsReady = true;
      continueRender(handle);
    });
  }, [handle]);
};
const Symbol: React.FC<{ name: SymbolName; cx: number; cy: number; opacity?: number }> = ({ name, cx, cy, opacity = 0.85 }) => {
  const { w, h } = symbols[name];
  return <image href={staticFile(`symbols/${name}.png`)} x={cx - w / 2} y={cy - h / 2} width={w} height={h} opacity={opacity} />;
};

// The capture row: close, mode, timer | archive, more, and the Capture button
// with a line for its label.
const CaptureRow: React.FC = () => (
  <g>
    <rect {...CAPTURE_BUTTON} fill="white" fillOpacity={0.1} />
    <rect x={GLYPH_AT.capture - 24} y={14 - 1.7} width={48} height={3.4} rx={1.7} fill="white" fillOpacity={0.6} />
    {panelGlyphs.map((g) => (
      <path key={g.name} d={g.d} fill={g.fill} fillOpacity={g.opacity} />
    ))}
  </g>
);

// The archive's header: back, the colour format menu (its label a line), pin,
// more. Placed as measured on the archive screenshot the README carried until
// 384d92e (`git show 384d92e:assets/screenshots/panel-archive.png`).
const more = panelGlyphs.find((g) => g.name === "more")!;
const ArchiveHeader: React.FC = () => (
  <g>
    <Symbol name="chevron.left" cx={GLYPH_AT.close} cy={16} />
    <rect x={55} y={16 - 1.7} width={21} height={3.4} rx={1.7} fill="white" fillOpacity={0.85} />
    <Symbol name="chevron.down" cx={86} cy={16.5} opacity={0.6} />
    <Symbol name="pin" cx={411} cy={16} />
    <g transform={`translate(${444 - GLYPH_AT.more} 2)`}>
      <path d={more.d} fill={more.fill} fillOpacity={more.opacity} />
    </g>
  </g>
);

// The archive's strip, newest first: what the other clips made (the colour
// just picked, the scanned text, the decorated shot), then older things.
type Tile = { kind: "color" | "text" | "shot" | "screen"; w: number; color?: string };
const STRIP: Tile[] = [
  { kind: "color", w: 30, color: PICKED },
  { kind: "text", w: 47 },
  { kind: "shot", w: 47 },
  { kind: "color", w: 30, color: "#53B58A" },
  { kind: "screen", w: 47 },
  { kind: "color", w: 30, color: "#EDC55B" },
  { kind: "text", w: 47 },
  { kind: "color", w: 30, color: "#7B5CF0" },
];
const STRIP_X = 31;
const STRIP_Y = 34;
const TILE_H = 30;
const GAP = 8;
export const ARCHIVE_H = 82 * PT;
export const stripTile = (k: number) => {
  let x = STRIP_X;
  for (let i = 0; i < k; i++) x += STRIP[i].w + GAP;
  return { x: panelX(x + STRIP[k].w / 2), y: (STRIP_Y + TILE_H / 2) * PT };
};

const TileFace: React.FC<{ tile: Tile; id: string }> = ({ tile, id }) => {
  const { w } = tile;
  const h = TILE_H;
  if (tile.kind === "color") return <rect width={w} height={h} rx={5} fill={tile.color} />;
  if (tile.kind === "text")
    return (
      <g>
        <rect width={w} height={h} rx={5} fill="#232323" />
        {[0.85, 1, 0.7, 0.9].map((k, i) => (
          <rect key={i} x={4} y={5 + i * 4.6} width={(w - 14) * k} height={2.2} rx={1.1} fill="white" fillOpacity={0.75} />
        ))}
        <Symbol name="text.viewfinder" cx={w - 3 - 5} cy={h - 3 - 4.5} opacity={0.5} />
      </g>
    );
  // Screenshots fill their tile, cropped, as in the app.
  const [bw, bh] = tile.kind === "shot" ? [PAGE.w, PAGE.h] : [SHOT.w, SHOT.h];
  const s = Math.max(w / bw, h / bh);
  return (
    <g>
      <clipPath id={id}>
        <rect width={w} height={h} rx={5} />
      </clipPath>
      <g clipPath={`url(#${id})`}>
        <g transform={`translate(${(w - bw * s) / 2} ${(h - bh * s) / 2}) scale(${s})`}>
          {tile.kind === "shot" ? <Artwork ink={[1, 1, 1]} decor={1} /> : <Shot />}
        </g>
      </g>
    </g>
  );
};

const Strip: React.FC<{ pop: number }> = ({ pop }) => {
  let x = STRIP_X;
  return (
    <g>
      {STRIP.map((tile, k) => {
        const at = x;
        x += tile.w + GAP;
        const p = Math.max(0, Math.min(1, pop * (STRIP.length + 2) - k));
        if (p <= 0) return null;
        return (
          <g key={k} transform={`translate(${at} ${STRIP_Y + (1 - p) * 4})`} opacity={p}>
            <TileFace tile={tile} id={`tile-${k}`} />
          </g>
        );
      })}
    </g>
  );
};

// The panel: `w`/`h` its body in screen units; `glyphs` fades the capture row
// in; `archive` (0..1) turns the row into the archive header and lets the
// strip pop in (`strip`, 0..1).
export const Panel: React.FC<{ w: number; h: number; glyphs: number; archive?: number; strip?: number }> = ({
  w,
  h,
  glyphs,
  archive = 0,
  strip = 0,
}) => (
  <g transform={`translate(${NOTCH_X} 0)`}>
    <path d={outline(w, h)} fill={INK} />
    {glyphs > 0 && (
      <g transform={`scale(${PT}) translate(${-PANEL_SVG.centre} 0)`}>
        {archive < 1 && (
          <g opacity={glyphs * (1 - archive)}>
            <CaptureRow />
          </g>
        )}
        {archive > 0 && (
          <g opacity={glyphs * archive}>
            <ArchiveHeader />
            <Strip pop={strip} />
          </g>
        )}
      </g>
    )}
  </g>
);

// The colour picker's HUD (ColorPickerHUD.swift): a dark plate beside the
// cursor with a 3 x 3 magnifier of 14 pt cells and the format and value as
// two lines; on a click it says "Copied" with a check, here a line and the
// check. It sits up and to the left of the cursor — one of the four places
// the app puts it — so the glove does not cover it.
const HUD = { pad: 8, cell: 14, gap: 10, text: 55, tail: 4, sideGap: 18, verticalGap: 14 };
export const ColorHUD: React.FC<{
  x: number;
  y: number;
  sample: (dx: number, dy: number) => string;
  copied: number;
  opacity: number;
}> = ({ x, y, sample, copied, opacity }) => {
  if (opacity <= 0) return null;
  const mag = HUD.cell * 3;
  const textW = HUD.text + (52 + 7 + 20 - HUD.text) * copied;
  const w = HUD.pad + mag + HUD.gap + textW + HUD.tail + HUD.pad;
  const h = HUD.pad * 2 + mag;
  const centre = sample(0, 0);
  const [r, g, b] = centre.slice(4, -1).split(",").map(Number);
  const light = 0.299 * r + 0.587 * g + 0.114 * b > 127;
  const tx = HUD.pad + mag + HUD.gap;
  return (
    <g
      transform={`translate(${x - HUD.sideGap * PT - w * PT} ${y - HUD.verticalGap * PT - h * PT}) scale(${PT})`}
      opacity={opacity}
    >
      <rect width={w} height={h} rx={12} fill="black" fillOpacity={0.82} stroke="white" strokeOpacity={0.1} filter="url(#hudShadow)" />
      <g transform={`translate(${HUD.pad} ${HUD.pad})`}>
        {[-1, 0, 1].flatMap((j) =>
          [-1, 0, 1].map((i) => (
            <rect key={`${i}${j}`} x={(i + 1) * HUD.cell} y={(j + 1) * HUD.cell} width={HUD.cell + 0.05} height={HUD.cell + 0.05} fill={sample(i, j)} />
          ))
        )}
        <g stroke="white" strokeOpacity={0.18} strokeWidth={0.5}>
          <path d={`M14 0V42M28 0V42M0 14H42M0 28H42`} />
        </g>
        <rect x={HUD.cell} y={HUD.cell} width={HUD.cell} height={HUD.cell} fill="none" stroke={light ? "black" : "white"} strokeOpacity={light ? 0.85 : 0.9} strokeWidth={1.5} />
        <rect width={mag} height={mag} rx={4} fill="none" stroke="white" strokeOpacity={0.22} />
      </g>
      <g opacity={1 - copied}>
        <rect x={tx} y={20 - 1.6} width={21} height={3.2} rx={1.6} fill="white" fillOpacity={0.4} />
        <rect x={tx} y={36 - 2.2} width={HUD.text} height={4.4} rx={2.2} fill="white" fillOpacity={0.9} />
      </g>
      {copied > 0 && (
        <g opacity={copied}>
          <rect x={tx} y={h / 2 - 2.4} width={52} height={4.8} rx={2.4} fill="white" fillOpacity={0.9} />
          <Symbol name="checkmark.circle" cx={tx + 52 + 7 + 10} cy={h / 2} opacity={0.8} />
        </g>
      )}
    </g>
  );
};
