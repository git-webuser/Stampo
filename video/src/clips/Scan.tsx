import React from "react";
import { useCurrentFrame } from "remotion";
import { NOTCH_X } from "../figma";
import { BLUE, Burst } from "../brand/pixels";
import { TEXT, TextCard, TextWindow } from "../scene";
import { CELL_MID, MID, REST, Stage } from "../stage";
import { bump, clamp01, into, lerp, out, seg, track } from "../timing";
import { toNotch, Trail } from "./common";

// 3. Scan. The glove frames the text, a pixel beam reads it line by line, the
// lines turn over into their translation, and a copy goes into the notch while
// the window fades back to its plain grey lines.
export const SCAN_FRAMES = 150;

const SCAN = { x0: 290, y0: 112, x1: 510, y1: 288 };
const CARD = { w: 200, h: 150 };
const CARD_FROM = { x: TEXT.x + 118 + 92, y: TEXT.y + 34 + 70 };

export const Scan: React.FC = () => {
  const f = useCurrentFrame();

  const drag = seg(f, 18, 34);
  const sel = seg(f, 17, 20, out) * (1 - seg(f, 58, 64));
  const read = seg(f, 36, 58, (t) => t);
  const flips = [0, 1, 2, 3, 4, 5].map((k) => clamp01((f - 62 - 3 * k) / 10));
  const reset = seg(f, 118, 134);

  const lift = seg(f, 88, 94, out);
  const fly = seg(f, 94, 114, into);
  const cardAt = toNotch(fly, CARD_FROM, { x: 540, y: 120 });
  const cardPrev = toNotch(Math.max(0, fly - 0.06), CARD_FROM, { x: 540, y: 120 });
  const cardScale = lerp(lerp(0.9, 1, lift), 0.05, fly * fly);
  const gulp = bump(f, 112, 124);

  const glove = track(f, [
    [0, REST.x, REST.y],
    [16, SCAN.x0, SCAN.y0],
    [18, SCAN.x0, SCAN.y0],
    [34, SCAN.x1, SCAN.y1],
    [88, SCAN.x1, SCAN.y1],
    [118, REST.x, REST.y],
  ]);
  const press = Math.max(bump(f, 15, 21) * 0.6, f >= 18 && f < 35 ? 0.6 : 0);

  return (
    <Stage
      cam={MID}
      panel={{ w: 84 + 24 * gulp, h: 15 + 2 * gulp, glyphs: 0 }}
      screen={
        <>
          <TextWindow read={read} flips={flips} reset={reset} />
          {sel > 0 && (
            <g opacity={sel}>
              <rect
                x={SCAN.x0}
                y={SCAN.y0}
                width={lerp(0, SCAN.x1 - SCAN.x0, drag)}
                height={lerp(0, SCAN.y1 - SCAN.y0, drag)}
                fill={BLUE}
                fillOpacity={0.06}
                stroke={BLUE}
                strokeWidth={1.4}
                strokeDasharray="5 3"
              />
              {read > 0 && read < 1 && (
                <rect x={SCAN.x0} y={lerp(SCAN.y0, SCAN.y1, read) - CELL_MID} width={SCAN.x1 - SCAN.x0} height={CELL_MID * 2} fill="url(#beamPixels)" />
              )}
            </g>
          )}
          {lift > 0 && fly < 1 && (
            <g transform={`translate(${cardAt.x} ${cardAt.y}) scale(${cardScale}) translate(${-CARD.w / 2} ${-CARD.h / 2})`} opacity={lift}>
              <g filter="url(#windowShadow)">
                <TextCard w={CARD.w} h={CARD.h} bg="white" />
              </g>
            </g>
          )}
        </>
      }
      under={<Burst cx={NOTCH_X} cy={6} r0={20} r1={56} rays={6} from={20} to={160} width={CELL_MID * 2} cell={CELL_MID} p={seg(f, 110, 128, (t) => t)} seed={4} />}
      over={<Trail at={cardAt} prev={cardPrev} gap={CARD.w * 0.4 * cardScale} opacity={fly > 0 ? bump(f, 94, 114) : 0} />}
      glove={{ ...glove, press }}
    />
  );
};
