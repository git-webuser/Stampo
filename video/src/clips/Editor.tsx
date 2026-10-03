import React from "react";
import { useCurrentFrame } from "remotion";
import { NOTCH_X } from "../figma";
import { Burst } from "../brand/pixels";
import { doodleHead } from "../brand/parts";
import { Artwork, DECOR_TOOL, Editor as EditorWindow, editorTool, INK_AT, PAGE, SHOT, SHOT_IN_PAGE, ShotBorder, THUMB_RADIUS } from "../scene";
import { CELL_MID, MID, Stage, REST } from "../stage";
import { between, bump, into, lerp, out, Pt, seg, track } from "../timing";
import { AppOnScreen, ShotAt, THUMB, THUMB_BORDER, toNotch, Trail } from "./common";

// 2. Editor. A fresh thumbnail slides in, a click opens it, the glove marks it
// up, Decor lays it on a page, and the result goes into the notch — leaving
// the screen as it was before the thumbnail arrived.
export const EDITOR_FRAMES = 204;

// The page box in the editor, and the shot's place in it before Decor.
const ART = { x: NOTCH_X - PAGE.w / 2, y: 232 - PAGE.h / 2 };
const ART_C = { x: NOTCH_X, y: 232 };
const INK: [number, number][] = [
  [56, 76],
  [79, 91],
  [93, 109],
];
const DECOR_AT = editorTool(DECOR_TOOL);

// Where the pen is, in screen space, for doodle i at progress p.
const pen = (i: number, p: number): Pt => {
  const d = INK_AT[i];
  const h = doodleHead(d.s, d.x, d.y, d.scale, p);
  return { x: ART.x + SHOT_IN_PAGE.x + h.x, y: ART.y + SHOT_IN_PAGE.y + h.y };
};

export const Editor: React.FC = () => {
  const f = useCurrentFrame();

  const slide = seg(f, 0, 14, out);
  const toEditor = seg(f, 32, 52);
  const editorOn = seg(f, 32, 50, out) * (1 - seg(f, 160, 170));
  const ink = INK.map(([a, b]) => seg(f, a, b, (t) => t));
  const decor = seg(f, 126, 152, out);
  const tool = between(f, 54, 77) ? 2 : between(f, 77, 92) ? 5 : between(f, 92, 110) ? 3 : between(f, 120, 160) ? DECOR_TOOL : null;

  const fly = seg(f, 162, 186, into);
  const flyAt = toNotch(fly, ART_C, { x: 560, y: 150 });
  const flyPrev = toNotch(Math.max(0, fly - 0.06), ART_C, { x: 560, y: 150 });
  const flyScale = lerp(1, 0.04, fly * fly);
  const gulp = bump(f, 184, 196);

  // The thumbnail: in from the right edge, then opened into the editor.
  const thumb = { x: lerp(720, THUMB.x, slide), y: THUMB.y, w: THUMB.w };
  const shot = {
    x: lerp(thumb.x, ART.x + SHOT_IN_PAGE.x, toEditor),
    y: lerp(thumb.y, ART.y + SHOT_IN_PAGE.y, toEditor),
    w: lerp(thumb.w, SHOT.w, toEditor),
  };
  const border = THUMB_BORDER * (1 - toEditor);
  const radius = lerp(THUMB_RADIUS, 6, toEditor);

  const keys: [number, number, number][] = [
    [0, REST.x, REST.y],
    [12, REST.x, REST.y],
    [24, THUMB.x + 52, THUMB.y + 39],
    [34, THUMB.x + 52, THUMB.y + 39],
    [46, 520, 300],
    [118, DECOR_AT.x, DECOR_AT.y],
    [126, DECOR_AT.x, DECOR_AT.y],
    [146, REST.x, REST.y],
  ];
  let glove: Pt = track(f, keys);
  // From 46 to the Decor click the glove holds the pen: it rides each stroke,
  // hops to the start of the next, and goes from the last to the Decor tool.
  const hop = (a: Pt, b: Pt, f0: number, f1: number): Pt => {
    const p = seg(f, f0, f1);
    return { x: lerp(a.x, b.x, p), y: lerp(a.y, b.y, p) };
  };
  if (f >= 46 && f < INK[0][0]) glove = hop(track(46, keys), pen(0, 0), 46, INK[0][0]);
  for (let i = 0; i < 3; i++) {
    const [a, b] = INK[i];
    if (f >= a && f < b) glove = pen(i, ink[i]);
    const next = INK[i + 1];
    if (next && f >= b && f < next[0]) glove = hop(pen(i, 1), pen(i + 1, 0), b, next[0]);
  }
  if (f >= INK[2][1] && f < 118) glove = hop(pen(2, 1), DECOR_AT, INK[2][1], 118);
  const drawing = f >= INK[0][0] && f < INK[2][1];
  const press = Math.max(bump(f, 24, 32), bump(f, 118, 126), drawing ? 0.6 : 0);

  return (
    <Stage
      cam={MID}
      panel={{ w: 84 + 24 * gulp, h: 15 + 2 * gulp, glyphs: 0 }}
      screen={
        <>
          <AppOnScreen />
          {editorOn > 0 && <EditorWindow opacity={editorOn} tool={tool} />}
          {f < 162 &&
            (toEditor <= 0 ? (
              <ShotAt x={shot.x} y={shot.y} w={shot.w} thumb={1} />
            ) : (
              <g transform={`translate(${shot.x - SHOT_IN_PAGE.x * (shot.w / SHOT.w)} ${shot.y - SHOT_IN_PAGE.y * (shot.w / SHOT.w)}) scale(${shot.w / SHOT.w})`}>
                <Artwork ink={ink} decor={decor} radius={radius} />
                {border > 0.05 && <ShotBorder border={border} radius={radius} x={SHOT_IN_PAGE.x} y={SHOT_IN_PAGE.y} />}
              </g>
            ))}
          {f >= 162 && fly < 1 && (
            <g transform={`translate(${flyAt.x} ${flyAt.y}) scale(${flyScale}) translate(${-PAGE.w / 2} ${-PAGE.h / 2})`}>
              <Artwork ink={[1, 1, 1]} decor={1} />
            </g>
          )}
        </>
      }
      under={<Burst cx={NOTCH_X} cy={6} r0={20} r1={56} rays={6} from={20} to={160} width={CELL_MID * 2} cell={CELL_MID} p={seg(f, 182, 198, (t) => t)} seed={2} />}
      over={<Trail at={flyAt} prev={flyPrev} gap={PAGE.w * 0.36 * flyScale} opacity={f >= 162 ? bump(f, 162, 186) : 0} />}
      glove={{ ...glove, press }}
    />
  );
};
