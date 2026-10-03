import React from "react";
import { getLength, getPointAtLength } from "@remotion/paths";
import { glove, hare, Stroke } from "./doodles";

// Brand paths come as several subpaths in one `d`. Dashing them as one would
// draw them all at once, so they are drawn one after another, each taking its
// share of the progress by length.
const subpaths = (d: string) => d.split(/(?=M)/).map((s) => s.trim()).filter(Boolean);

const split = new Map<string, { d: string; len: number }[]>();
const parts = (d: string) => {
  let hit = split.get(d);
  if (!hit) {
    hit = subpaths(d).map((s) => ({ d: s, len: getLength(s) }));
    split.set(d, hit);
  }
  return hit;
};

// A doodle placed with its bbox's top-left at (x, y), scaled by `scale`,
// drawn on as `p` goes 0..1.
export const Doodle: React.FC<{
  s: Stroke;
  color: string;
  x: number;
  y: number;
  scale: number;
  p: number;
  opacity?: number;
  cap?: "round" | "butt";
}> = ({ s, color, x, y, scale, p, opacity = 1, cap = "round" }) => {
  if (p <= 0) return null;
  const ps = parts(s.d);
  const total = ps.reduce((a, b) => a + b.len, 0);
  let left = p * total;
  return (
    <g
      transform={`translate(${x} ${y}) scale(${scale}) translate(${-s.bbox[0]} ${-s.bbox[1]})`}
      opacity={opacity}
    >
      {ps.map((part, k) => {
        const shown = Math.max(0, Math.min(part.len, left));
        left -= part.len;
        if (shown <= 0) return null;
        return (
          <path
            key={k}
            d={part.d}
            fill="none"
            stroke={color}
            strokeWidth={s.width}
            strokeLinecap={cap}
            strokeLinejoin="round"
            strokeDasharray={`${part.len} ${part.len}`}
            strokeDashoffset={part.len - shown}
          />
        );
      })}
    </g>
  );
};

// Where the pen is when a Doodle placed the same way is at `p`.
export const doodleHead = (s: Stroke, x: number, y: number, scale: number, p: number) => {
  const ps = parts(s.d);
  const total = ps.reduce((a, b) => a + b.len, 0);
  let left = Math.max(0, Math.min(1, p)) * total;
  for (const part of ps) {
    if (left <= part.len) {
      const pt = getPointAtLength(part.d, Math.min(left, part.len - 1e-3))!;
      return { x: x + (pt.x - s.bbox[0]) * scale, y: y + (pt.y - s.bbox[1]) * scale };
    }
    left -= part.len;
  }
  const last = ps[ps.length - 1];
  const pt = getPointAtLength(last.d, last.len - 1e-3)!;
  return { x: x + (pt.x - s.bbox[0]) * scale, y: y + (pt.y - s.bbox[1]) * scale };
};

// The glove from the DMG background, its fingertip at (x, y).
const TIP = { x: 301.5, y: 244.8 };
export const Glove: React.FC<{ x: number; y: number; scale: number; press?: number; opacity?: number }> = ({
  x,
  y,
  scale,
  press = 0,
  opacity = 1,
}) => {
  if (opacity <= 0) return null;
  const k = scale * (1 - 0.14 * press);
  return (
    <g
      transform={`translate(${x} ${y}) scale(${k}) translate(${-TIP.x} ${-TIP.y})`}
      opacity={opacity}
      filter="url(#gloveShadow)"
    >
      <path d={glove.fill} fill="white" />
      <path d={glove.outline} fill="none" stroke="#0C131D" strokeWidth={glove.width} />
    </g>
  );
};

// The hare's head, its bbox's top-centre at (x, y).
export const Hare: React.FC<{ x: number; y: number; scale: number }> = ({ x, y, scale }) => {
  const [bx, by, bw] = hare.bbox;
  return (
    <g transform={`translate(${x} ${y}) scale(${scale}) translate(${-(bx + bw / 2)} ${-by})`}>
      <path d={hare.head} fill="white" stroke="#0C131D" strokeWidth={hare.width} />
      {hare.eyes.map((d, k) => (
        <path key={k} d={d} fill="#0C131D" />
      ))}
    </g>
  );
};
