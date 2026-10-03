import React from "react";
import { getLength, getPointAtLength } from "@remotion/paths";

// The checker on the banner, the social preview and the DMG background,
// sampled cell by cell from assets/dmg-background@4x.png: three colours in a
// 4 x 4 repeat. Figma's SVG export drops this texture, so it is drawn here.
export const BLUE = "#198CFE";
export const VIOLET = "#8C8CFE";
export const CYAN = "#8CFEFE";
const COLOR: Record<string, string> = { B: BLUE, V: VIOLET, C: CYAN };
const TILE = ["CVCB", "BVBV", "CBCV", "BVBV"];
const mod4 = (n: number) => ((n % 4) + 4) % 4;
export const pixelColor = (i: number, j: number) =>
  COLOR[TILE[mod4(j)][mod4(i)]];

type Cell = { i: number; j: number; t: number };
const cache = new Map<string, Cell[]>();

// The cells of a `cell`-sized grid that a stroke of `width` along `d` covers,
// each tagged with how far along the path it sits (0..1) so the stroke can be
// drawn on, or erased, a cell at a time.
const cellsAlong = (d: string, width: number, cell: number): Cell[] => {
  const key = `${d}|${width}|${cell}`;
  const hit = cache.get(key);
  if (hit) return hit;
  const length = getLength(d);
  const n = Math.max(8, Math.ceil(length / (cell / 3)));
  const pts: [number, number, number][] = [];
  for (let k = 0; k <= n; k++) {
    // getPointAtLength returns null a hair past the end, so stay inside it.
    const p = getPointAtLength(d, Math.min(length - 1e-3, (length * k) / n));
    if (p) pts.push([p.x, p.y, k / n]);
  }
  const r = width / 2;
  const xs = pts.map((p) => p[0]);
  const ys = pts.map((p) => p[1]);
  const cells: Cell[] = [];
  for (let i = Math.floor((Math.min(...xs) - r) / cell); i <= Math.ceil((Math.max(...xs) + r) / cell); i++) {
    for (let j = Math.floor((Math.min(...ys) - r) / cell); j <= Math.ceil((Math.max(...ys) + r) / cell); j++) {
      const cx = (i + 0.5) * cell;
      const cy = (j + 0.5) * cell;
      let best = Infinity;
      let bt = 0;
      for (const [x, y, t] of pts) {
        const dd = (x - cx) ** 2 + (y - cy) ** 2;
        if (dd < best) {
          best = dd;
          bt = t;
        }
      }
      if (best <= r * r) cells.push({ i, j, t: bt });
    }
  }
  cache.set(key, cells);
  return cells;
};

export const PixelStroke: React.FC<{
  d: string;
  width: number;
  cell: number;
  head?: number;
  tail?: number;
  opacity?: number;
}> = ({ d, width, cell, head = 1, tail = 0, opacity = 1 }) => {
  if (head <= tail || opacity <= 0) return null;
  const cells = cellsAlong(d, width, cell);
  return (
    <g opacity={opacity}>
      {cells
        .filter((c) => c.t <= head && c.t >= tail)
        .map((c) => (
          <rect
            key={`${c.i}:${c.j}`}
            x={c.i * cell}
            y={c.j * cell}
            width={cell + 0.04}
            height={cell + 0.04}
            fill={pixelColor(c.i, c.j)}
          />
        ))}
    </g>
  );
};

// A <pattern> of the same checker, for filling areas rather than strokes.
export const PixelPattern: React.FC<{ id: string; cell: number }> = ({ id, cell }) => (
  <pattern id={id} patternUnits="userSpaceOnUse" width={cell * 4} height={cell * 4}>
    {TILE.flatMap((row, j) =>
      row.split("").map((ch, i) => (
        <rect key={`${i}${j}`} x={i * cell} y={j * cell} width={cell + 0.04} height={cell + 0.04} fill={COLOR[ch]} />
      ))
    )}
  </pattern>
);

// Rays out of a point, as separate strokes so each can be drawn on by itself.
export const Burst: React.FC<{
  cx: number;
  cy: number;
  r0: number;
  r1: number;
  rays: number;
  from?: number; // degrees, 0 = right, 90 = down
  to?: number;
  width: number;
  cell: number;
  p: number; // 0..1 over the burst's life
  seed?: number;
}> = ({ cx, cy, r0, r1, rays, from = 0, to = 360, width, cell, p, seed = 1 }) => {
  if (p <= 0 || p >= 1) return null;
  const head = Math.min(1, p / 0.45);
  const tail = Math.max(0, (p - 0.4) / 0.6);
  return (
    <g>
      {Array.from({ length: rays }, (_, k) => {
        const jitter = Math.sin(seed * 97 + k * 13.7) * 0.5 + 0.5;
        const span = to - from;
        const a = ((from + (span * (k + 0.5)) / rays + (jitter - 0.5) * (span / rays) * 0.5) * Math.PI) / 180;
        const len = r0 + (r1 - r0) * (0.7 + 0.3 * jitter);
        const d = `M ${cx + Math.cos(a) * r0} ${cy + Math.sin(a) * r0} L ${cx + Math.cos(a) * len} ${cy + Math.sin(a) * len}`;
        return <PixelStroke key={k} d={d} width={width} cell={cell} head={head} tail={tail} />;
      })}
    </g>
  );
};
