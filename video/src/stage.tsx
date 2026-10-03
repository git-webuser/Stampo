import React from "react";
import { AbsoluteFill } from "remotion";
import { Laptop, NOTCH_X, SCREEN } from "./figma";
import { BLUE, CYAN, PixelPattern, VIOLET } from "./brand/pixels";
import { Glove, Hare } from "./brand/parts";
import { Panel, usePreloadSymbols } from "./panel";
import { PHOTO } from "./scene";
import { Cam, Pt } from "./timing";

export const WIDTH = 1600;
export const HEIGHT = 800;

// Shots in laptop space. The notch close-up (2.8) is the onboarding's own.
export const NOTCH: Cam = { x: 599, y: 240, s: 2.8 };
export const MID: Cam = { x: 599, y: 372, s: 1.62 };

// Pixel size per shot, so the checker reads the same ~11 px on screen.
export const CELL_NOTCH = 4;
export const CELL_MID = 6.8;

// Where things thrown into the notch land, in screen coordinates.
export const NOTCH_IN: Pt = { x: NOTCH_X, y: 6 };
export const REST: Pt = { x: 600, y: 330 }; // the glove, idle, lower right

export type PanelState = { w: number; h: number; glyphs: number; archive?: number; strip?: number };

const Defs: React.FC = () => (
  <defs>
    <pattern id="dots" patternUnits="userSpaceOnUse" width={32} height={32}>
      <circle cx={16} cy={16} r={1.7} fill="#DCE3EC" />
    </pattern>
    <filter id="windowShadow" x="-30%" y="-30%" width="160%" height="170%">
      <feDropShadow dx={0} dy={6} stdDeviation={9} floodColor="#000" floodOpacity={0.12} />
      <feDropShadow dx={0} dy={1} stdDeviation={1} floodColor="#000" floodOpacity={0.08} />
    </filter>
    <filter id="shotShadow" x="-30%" y="-30%" width="160%" height="170%">
      <feDropShadow dx={0} dy={10} stdDeviation={12} floodColor="#0C131D" floodOpacity={0.28} />
    </filter>
    <filter id="hudShadow" x="-30%" y="-30%" width="160%" height="180%">
      <feDropShadow dx={0} dy={4} stdDeviation={10} floodColor="#000" floodOpacity={0.45} />
    </filter>
    <filter id="gloveShadow" x="-40%" y="-40%" width="180%" height="180%">
      <feDropShadow dx={0} dy={4} stdDeviation={3} floodColor="#0C131D" floodOpacity={0.25} />
    </filter>
    <linearGradient id="shotBg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stopColor="#D6D6D6" />
      <stop offset="1" stopColor="#8E8E8E" />
    </linearGradient>
    <linearGradient id="pageGradient" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stopColor={BLUE} />
      <stop offset="0.55" stopColor={VIOLET} />
      <stop offset="1" stopColor={CYAN} />
    </linearGradient>
    <PixelPattern id="beamPixels" cell={CELL_MID} />
    <clipPath id="screenClip">
      <rect width={SCREEN.w} height={SCREEN.h} />
    </clipPath>
    <clipPath id="photoClip">
      <rect width={PHOTO.w} height={PHOTO.h} rx={11} />
    </clipPath>
  </defs>
);

// One frame of any clip: the dotted page, the onboarding's laptop under a
// camera, and the layers a clip fills in, all but `world` in screen
// coordinates (704 x 457, origin at the screen's top-left corner).
export const Stage: React.FC<{
  cam: Cam;
  panel: PanelState;
  screen?: React.ReactNode; // clipped to the screen, under the panel
  under?: React.ReactNode; // not clipped, under the panel: bursts out of the notch
  over?: React.ReactNode; // above the panel: loupe, things in flight
  glove?: Pt & { press?: number; opacity?: number };
  hareY?: number; // top of the hare's head, laptop space; behind the lid
  hareScale?: number;
  world?: React.ReactNode; // laptop space, above the laptop
}> = ({ cam, panel, screen, under, over, glove, hareY, hareScale = 2.2, world }) => {
  usePreloadSymbols();
  return (
  <AbsoluteFill style={{ backgroundColor: "white" }}>
    <svg width={WIDTH} height={HEIGHT} viewBox={`0 0 ${WIDTH} ${HEIGHT}`}>
      <Defs />
      <rect width={WIDTH} height={HEIGHT} fill="url(#dots)" />
      <g transform={`translate(${WIDTH / 2} ${HEIGHT / 2}) scale(${cam.s}) translate(${-cam.x} ${-cam.y})`}>
        {hareY !== undefined && <Hare x={SCREEN.x + NOTCH_X} y={hareY} scale={hareScale} />}
        <Laptop />
        <g transform={`translate(${SCREEN.x} ${SCREEN.y})`}>
          <g clipPath="url(#screenClip)">{screen}</g>
          {under}
          <Panel w={panel.w} h={panel.h} glyphs={panel.glyphs} archive={panel.archive} strip={panel.strip} />
          {over}
          {glove && (
            <Glove
              x={glove.x}
              y={glove.y}
              scale={1.15 / cam.s}
              press={glove.press ?? 0}
              opacity={Math.max(0, Math.min(1, glove.opacity ?? 1))}
            />
          )}
        </g>
        {world}
      </g>
    </svg>
  </AbsoluteFill>
);
};
