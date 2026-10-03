import React from "react";
import { Easing, useCurrentFrame } from "remotion";
import { NOTCH_X, SCREEN } from "../figma";
import { Burst } from "../brand/pixels";
import { Doodle } from "../brand/parts";
import { star } from "../brand/doodles";
import { GLYPH_AT } from "../brand/panel";
import { GLYPH_Y, PANEL_OPEN, panelX } from "../panel";
import { CELL_NOTCH, MID, NOTCH, Stage } from "../stage";
import { between, bump, camera, into, lerp, out, overshoot, seg, track } from "../timing";
import { AppOnScreen, SEL, ShotAt, THUMB, toNotch } from "./common";

// 1. Capture. A click on the notch opens the panel, the Capture button is
// pressed (as in the onboarding), the window is framed, and the shot drops into the corner — then goes into
// the notch while the camera returns to it, which is where the loop began.
export const CAPTURE_FRAMES = 168;

const CAPTURE = { x: panelX(GLYPH_AT.capture), y: GLYPH_Y };
const START = { x: 560, y: 200 };

export const Capture: React.FC = () => {
  const f = useCurrentFrame();
  const cam = camera(f, [
    [0, NOTCH],
    [56, NOTCH],
    [84, MID],
    [136, MID],
    [162, NOTCH],
  ]);

  const opened = seg(f, 18, 32, overshoot);
  const closing = seg(f, 148, 162);
  const gulp = bump(f, 152, 164);
  const panel = {
    w: lerp(84, PANEL_OPEN, opened) - (PANEL_OPEN - 84) * closing + 22 * gulp,
    h: 15 + 2 * gulp,
    glyphs: seg(f, 26, 36, out) * (1 - seg(f, 146, 154)),
  };

  const drag = seg(f, 88, 110);
  const selX1 = lerp(SEL.x0, SEL.x1, drag);
  const selY1 = lerp(SEL.y0, SEL.y1, drag);
  const dim = seg(f, 86, 93, (t) => t) * (1 - seg(f, 112, 118));
  const flash = bump(f, 109, 117);

  // The shot: the selection shrinking to the thumbnail, then thrown at the notch.
  const toThumb = seg(f, 116, 134, Easing.bezier(0.4, 0, 0.2, 1));
  const fly = seg(f, 140, 158, into);
  const thumbC = { x: THUMB.x + THUMB.w / 2, y: THUMB.y + THUMB.h / 2 };
  const c = toNotch(fly, thumbC, { x: 650, y: 110 });
  const w = fly > 0 ? lerp(THUMB.w, 6, fly * fly) : lerp(SEL.x1 - SEL.x0, THUMB.w, toThumb);
  const h = (w * 3) / 4;
  const shotX = fly > 0 ? c.x - w / 2 : lerp(SEL.x0, THUMB.x, toThumb);
  const shotY = fly > 0 ? c.y - h / 2 : lerp(SEL.y0, THUMB.y, toThumb);

  const glove = track(f, [
    [0, START.x, START.y],
    [14, 356, 9],
    [34, 356, 9],
    [48, CAPTURE.x, CAPTURE.y],
    [56, CAPTURE.x, CAPTURE.y],
    [84, SEL.x0, SEL.y0],
    [88, SEL.x0, SEL.y0],
    [110, SEL.x1, SEL.y1],
    [113, SEL.x1, SEL.y1],
    [138, 600, 320],
    [164, START.x, START.y],
  ]);
  const press = Math.max(bump(f, 14, 22), bump(f, 48, 56), between(f, 88, 111) ? 0.6 : 0, bump(f, 84, 90) * 0.6);

  return (
    <Stage
      cam={cam}
      panel={panel}
      screen={
        <>
          <AppOnScreen />
          {dim > 0 && (
            <g opacity={dim}>
              <path
                d={`M0 0H${SCREEN.w}V${SCREEN.h}H0Z M${SEL.x0} ${SEL.y0}V${selY1}H${selX1}V${SEL.y0}Z`}
                fill="black"
                fillOpacity={0.22}
                fillRule="evenodd"
              />
              <rect x={SEL.x0} y={SEL.y0} width={selX1 - SEL.x0} height={selY1 - SEL.y0} fill="none" stroke="white" strokeWidth={1} />
            </g>
          )}
          {flash > 0 && (
            <rect x={SEL.x0} y={SEL.y0} width={SEL.x1 - SEL.x0} height={SEL.y1 - SEL.y0} fill="white" opacity={flash * 0.85} />
          )}
          {f >= 116 && fly < 1 && <ShotAt x={shotX} y={shotY} w={w} thumb={toThumb} />}
        </>
      }
      under={
        <Burst cx={NOTCH_X} cy={4} r0={30} r1={92} rays={6} from={8} to={172} width={CELL_NOTCH * 2.2} cell={CELL_NOTCH} p={seg(f, 18, 54, (t) => t)} seed={1} />
      }
      over={<Doodle s={star} color="#5CF2F5" x={NOTCH_X + 132} y={16} scale={0.42} p={seg(f, 26, 40, out)} opacity={1 - seg(f, 56, 64)} />}
      glove={{ ...glove, press }}
    />
  );
};
