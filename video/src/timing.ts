import { Easing } from "remotion";

export const FPS = 30;

export const clamp01 = (v: number) => Math.max(0, Math.min(1, v));
export const lerp = (a: number, b: number, p: number) => a + (b - a) * p;

export const inOut = Easing.bezier(0.65, 0, 0.35, 1);
export const out = Easing.bezier(0.22, 1, 0.36, 1);
export const into = Easing.bezier(0.55, 0, 1, 0.45);
export const overshoot = Easing.bezier(0.34, 1.56, 0.64, 1);
export const linear = (t: number) => t;

// 0..1 across frames a..b.
export const seg = (f: number, a: number, b: number, e: (t: number) => number = inOut) =>
  e(clamp01((f - a) / (b - a)));
// 0 → 1 → 0 across frames a..b.
export const bump = (f: number, a: number, b: number) => Math.sin(Math.PI * clamp01((f - a) / (b - a)));
export const between = (f: number, a: number, b: number) => f >= a && f < b;

export type Pt = { x: number; y: number };

// A point moving through [frame, x, y] keys, eased between each pair.
export type Key = [number, number, number];
export const track = (f: number, keys: Key[], e = inOut): Pt => {
  if (f <= keys[0][0]) return { x: keys[0][1], y: keys[0][2] };
  for (let k = 0; k < keys.length - 1; k++) {
    const [f0, x0, y0] = keys[k];
    const [f1, x1, y1] = keys[k + 1];
    if (f <= f1) {
      const p = f1 === f0 ? 1 : e((f - f0) / (f1 - f0));
      return { x: lerp(x0, x1, p), y: lerp(y0, y1, p) };
    }
  }
  const last = keys[keys.length - 1];
  return { x: last[1], y: last[2] };
};

// A quadratic Bézier, for things thrown along an arc.
export const quad = (p: number, a: Pt, c: Pt, b: Pt): Pt => ({
  x: (1 - p) * (1 - p) * a.x + 2 * (1 - p) * p * c.x + p * p * b.x,
  y: (1 - p) * (1 - p) * a.y + 2 * (1 - p) * p * c.y + p * p * b.y,
});

// Camera: the laptop-space point at the frame's centre, and the zoom.
export type Cam = { x: number; y: number; s: number };
export const camera = (f: number, keys: [number, Cam][]): Cam => {
  for (let k = 0; k < keys.length - 1; k++) {
    const [f0, a] = keys[k];
    const [f1, b] = keys[k + 1];
    if (f <= f1) {
      const p = f <= f0 ? 0 : inOut((f - f0) / (f1 - f0));
      // Zoom moves evenly in log space, or a pull-back lurches.
      return { x: lerp(a.x, b.x, p), y: lerp(a.y, b.y, p), s: Math.exp(lerp(Math.log(a.s), Math.log(b.s), p)) };
    }
  }
  return keys[keys.length - 1][1];
};
