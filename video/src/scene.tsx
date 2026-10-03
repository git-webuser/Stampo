import React from "react";
import { BLUE, CYAN, VIOLET } from "./brand/pixels";
import { Doodle } from "./brand/parts";
import { curlyArrow, flower, loopArrow, star } from "./brand/doodles";
import { lerp } from "./timing";

// Everything here is drawn in the screen's own coordinates (704 x 457, the
// notch's centre at x = 352), in the onboarding's grey, schematic language:
// translucent white windows, a black panel, no words.

// The onboarding's window: white at 60% over the screen, a sidebar at 88/312.
export const AppWindow: React.FC<{
  x: number;
  y: number;
  w: number;
  h: number;
  sidebar?: number;
  opacity?: number;
  fill?: number;
  children?: React.ReactNode;
}> = ({ x, y, w, h, sidebar = 88 / 312, opacity = 1, fill = 0.6, children }) => {
  const r = 11;
  const sx = w * sidebar;
  return (
    <g transform={`translate(${x} ${y})`} opacity={opacity}>
      <g filter="url(#windowShadow)">
        <rect width={w} height={h} rx={r} fill="white" fillOpacity={fill} />
        {sidebar > 0 && (
          <path
            d={`M ${sx} 0 H ${w - r} Q ${w} 0 ${w} ${r} V ${h - r} Q ${w} ${h} ${w - r} ${h} H ${sx} Z`}
            fill="white"
            fillOpacity={0.6}
          />
        )}
      </g>
      {children}
    </g>
  );
};

// What the capture takes: a stretch of the grey screen with the window on it.
// Drawn in a 348 x 261 box, the selection's own size. As a thumbnail it gets
// the onboarding's frame: rounded corners and a dark border inside them. The
// border's own corners are the outline's radius less half its width, or the
// grey shows through outside it at the corners.
export const SHOT = { w: 348, h: 261 };
export const THUMB_RADIUS = 20; // the onboarding thumbnail's 6 px, in shot units
export const Shot: React.FC<{ border?: number; radius?: number }> = ({ border = 0, radius = 6 }) => (
  <g>
    <rect width={SHOT.w} height={SHOT.h} rx={radius} fill="url(#shotBg)" />
    <AppWindow x={18} y={21} w={312} h={220} />
    {border > 0 && <ShotBorder border={border} radius={radius} />}
  </g>
);
export const ShotBorder: React.FC<{ border: number; radius: number; x?: number; y?: number }> = ({ border, radius, x = 0, y = 0 }) => (
  <rect
    x={x + border / 2}
    y={y + border / 2}
    width={SHOT.w - border}
    height={SHOT.h - border}
    rx={Math.max(0, radius - border / 2)}
    fill="none"
    stroke="black"
    strokeOpacity={0.8}
    strokeWidth={border}
  />
);

// The marked-up, decorated picture, in a 380 x 285 page box. `ink` draws the
// markup on in three strokes; `decor` grows the page out from behind the shot.
// The page is the checker's three colours as a smooth blend: the hard-edged
// checker made this the heaviest stretch of the WebP by far.
export const PAGE = { w: 380, h: 285 };
export const INK_AT = [
  { s: loopArrow, x: 22, y: 150, scale: 0.8, color: "#0C131D" },
  { s: star, x: 270, y: 14, scale: 1.1, color: "#5CF2F5" },
  { s: curlyArrow, x: 262, y: 150, scale: 0.75, color: BLUE },
];
export const SHOT_IN_PAGE = { x: 16, y: 12 }; // where the shot sits before Decor
export const Artwork: React.FC<{ ink: number[]; decor: number; radius?: number }> = ({ ink, decor, radius = 6 }) => {
  const s0 = { x: SHOT_IN_PAGE.x, y: SHOT_IN_PAGE.y, w: SHOT.w, h: SHOT.h };
  const s1 = { x: 48, y: 36, w: 284, h: 213 };
  const k = lerp(1, s1.w / s0.w, decor);
  return (
    <g>
      {decor > 0 && (
        <rect
          x={lerp(s0.x, 0, decor)}
          y={lerp(s0.y, 0, decor)}
          width={lerp(s0.w, PAGE.w, decor)}
          height={lerp(s0.h, PAGE.h, decor)}
          rx={lerp(6, 16, decor)}
          fill="url(#pageGradient)"
          opacity={Math.min(1, decor * 3)}
        />
      )}
      <g
        transform={`translate(${lerp(s0.x, s1.x, decor)} ${lerp(s0.y, s1.y, decor)}) scale(${k})`}
        filter={decor > 0 ? "url(#shotShadow)" : undefined}
      >
        <Shot radius={radius} />
        {INK_AT.map((d, i) => (
          <Doodle key={i} s={d.s} color={d.color} x={d.x} y={d.y} scale={d.scale} p={ink[i] ?? 0} />
        ))}
      </g>
    </g>
  );
};

// The editor: a plain window with a row of tool glyphs along the top.
export const EDITOR = { x: 117, y: 46, w: 470, h: 344, bar: 28 };
export const editorTool = (k: number) => ({ x: EDITOR.x + 24 + k * 22, y: EDITOR.y + EDITOR.bar / 2 });
export const DECOR_TOOL = 9;
export const Editor: React.FC<{ opacity: number; tool: number | null }> = ({ opacity, tool }) => (
  <g opacity={opacity}>
    <AppWindow x={EDITOR.x} y={EDITOR.y} w={EDITOR.w} h={EDITOR.h} sidebar={0} fill={0.92} />
    {Array.from({ length: 10 }, (_, k) => {
      const t = editorTool(k);
      const on = tool === k;
      return (
        <rect
          key={k}
          x={t.x - 6}
          y={t.y - 6}
          width={12}
          height={12}
          rx={3.5}
          fill={on ? BLUE : "#000"}
          fillOpacity={on ? 1 : k === DECOR_TOOL ? 0.16 : 0.09}
        />
      );
    })}
  </g>
);

// A window of text: grey bars. `read` (0..1) is the scan beam's way down,
// turning the lines it has passed blue; `flips` (0..1 per line) turn each one
// over into its translation, violet and of a different length; `reset` fades
// the plain grey lines back in over whatever is showing.
export const LINES_A = [176, 148, 190, 120, 168, 98];
export const LINES_B = [138, 182, 112, 176, 132, 158];
export const TEXT = { x: 182, y: 92, w: 340, h: 226 };
export const LINE0 = { x: 118, y: 34, step: 28 }; // in the window
const Lines: React.FC<{ read: number; flips: number[] }> = ({ read, flips }) => (
  <>
    {LINES_A.map((wa, k) => {
      const f = flips[k] ?? 0;
      const turned = f > 0.5;
      const passed = read * (LINES_A.length + 0.5) > k + 0.5;
      return (
        <g key={k} transform={`translate(${LINE0.x} ${LINE0.y + k * LINE0.step}) scale(1 ${Math.abs(Math.cos(Math.PI * f))})`}>
          <rect
            x={0}
            y={-4.5}
            width={turned ? LINES_B[k] : wa}
            height={9}
            rx={4.5}
            fill={turned ? VIOLET : passed ? BLUE : "#000"}
            fillOpacity={turned || passed ? 1 : 0.13}
          />
        </g>
      );
    })}
  </>
);
export const TextWindow: React.FC<{ read: number; flips: number[]; reset?: number }> = ({ read, flips, reset = 0 }) => (
  <AppWindow x={TEXT.x} y={TEXT.y} w={TEXT.w} h={TEXT.h}>
    {reset < 1 && (
      <g opacity={1 - reset}>
        <Lines read={read} flips={flips} />
      </g>
    )}
    {reset > 0 && (
      <g opacity={reset}>
        <Lines read={0} flips={[]} />
      </g>
    )}
  </AppWindow>
);

// A picture window with something colourful in it to pick from: the page
// gradient, with a doodle or two on it. (The hard-edged checker that stood
// here first doubled the clip's WebP: the camera's zoom re-encodes all of it.)
export const PHOTO = { x: 182, y: 92, w: 340, h: 226 };
export const PhotoWindow: React.FC = () => (
  <AppWindow x={PHOTO.x} y={PHOTO.y} w={PHOTO.w} h={PHOTO.h} sidebar={0}>
    <g clipPath="url(#photoClip)">
      <rect width={PHOTO.w} height={PHOTO.h} fill="url(#pageGradient)" />
      <Doodle s={flower} color="white" x={30} y={44} scale={1.25} p={1} opacity={0.75} />
      <Doodle s={star} color="white" x={262} y={34} scale={1.2} p={1} />
    </g>
  </AppWindow>
);

// The page gradient's colour at t (0..1 along its diagonal), and at a point
// of the picture window, so the loupe and the picked colour tell the truth.
const STOPS: [number, string][] = [
  [0, BLUE],
  [0.55, VIOLET],
  [1, CYAN],
];
const rgb = (hex: string) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
export const gradientAt = (t: number) => {
  const u = Math.max(0, Math.min(1, t));
  const k = u <= STOPS[1][0] ? 0 : 1;
  const [t0, c0] = STOPS[k];
  const [t1, c1] = STOPS[k + 1];
  const p = (u - t0) / (t1 - t0);
  const [a, b] = [rgb(c0), rgb(c1)];
  return `rgb(${a.map((v, i) => Math.round(v + (b[i] - v) * p)).join(",")})`;
};
// objectBoundingBox (0,0)→(1,1): the colour depends on (u + v) / 2.
export const photoColor = (x: number, y: number) =>
  gradientAt(((x - PHOTO.x) / PHOTO.w + (y - PHOTO.y) / PHOTO.h) / 2);

// Where the Archive clip's picker stops, and the colour it picks there.
export const PICK_AT = { x: 392, y: 206 };
export const PICKED = photoColor(PICK_AT.x, PICK_AT.y);

// A card of recognised text, as it flies into the notch.
export const TextCard: React.FC<{ w: number; h: number; bg?: string }> = ({ w, h, bg = "#2A2929" }) => (
  <g>
    <rect width={w} height={h} rx={7} fill={bg} />
    {[0.7, 0.9, 0.55, 0.8].map((k, i) => (
      <rect key={i} x={w * 0.13} y={h * 0.2 + i * h * 0.17} width={w * 0.74 * k} height={h * 0.072} rx={h * 0.036} fill={VIOLET} />
    ))}
  </g>
);
