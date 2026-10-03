import React from "react";
import { VIOLET } from "../brand/pixels";
import { Doodle } from "../brand/parts";
import { speedLines } from "../brand/doodles";
import { AppWindow, Shot, SHOT, THUMB_RADIUS } from "../scene";
import { NOTCH_IN } from "../stage";
import { Pt, quad } from "../timing";

// The app window every clip starts from, where the onboarding has it.
export const APP = { x: 196, y: 86, w: 312, h: 220 };
export const AppOnScreen: React.FC = () => <AppWindow x={APP.x} y={APP.y} w={APP.w} h={APP.h} />;

// The capture: the selection around the window, and the thumbnail it leaves
// in the corner, where the onboarding puts it.
export const SEL = { x0: 178, y0: 65, x1: 526, y1: 326 };
export const THUMB = { x: 582, y: 368, w: 104, h: 78 };
export const THUMB_BORDER = 9.7; // the onboarding's 2.9 px frame, in shot units

// `thumb` (0..1) is how far it has become the thumbnail: its frame and its
// rounded corners come in together.
export const ShotAt: React.FC<{ x: number; y: number; w: number; thumb: number }> = ({ x, y, w, thumb }) => (
  <g transform={`translate(${x} ${y}) scale(${w / SHOT.w})`} filter="url(#windowShadow)">
    <Shot border={THUMB_BORDER * thumb} radius={THUMB_RADIUS * thumb} />
  </g>
);

// Something thrown into the notch along an arc that swings out to `via`.
export const toNotch = (p: number, from: Pt, via: Pt) => quad(p, from, via, NOTCH_IN);

// Violet speed lines trailing whatever is at `at`, flying from `prev`.
export const Trail: React.FC<{ at: Pt; prev: Pt; gap: number; opacity: number }> = ({ at, prev, gap, opacity }) => {
  if (opacity <= 0) return null;
  const a = (Math.atan2(prev.y - at.y, prev.x - at.x) * 180) / Math.PI;
  return (
    <g transform={`translate(${at.x} ${at.y}) rotate(${a - 18})`} opacity={opacity}>
      <Doodle s={speedLines} color={VIOLET} x={gap} y={-18} scale={0.7} p={1} />
    </g>
  );
};
