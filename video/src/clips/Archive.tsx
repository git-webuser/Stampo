import React from "react";
import { useCurrentFrame } from "remotion";
import { NOTCH_X, SCREEN } from "../figma";
import { Burst } from "../brand/pixels";
import { Doodle } from "../brand/parts";
import { star } from "../brand/doodles";
import { GLYPH_AT } from "../brand/panel";
import { ARCHIVE_H, ColorHUD, GLYPH_Y, PANEL_OPEN, panelX, PT, stripTile } from "../panel";
import { photoColor, PhotoWindow, PICK_AT, PICKED } from "../scene";
import { CELL_NOTCH, REST, Stage } from "../stage";
import { bump, Cam, camera, into, lerp, out, overshoot, seg, track } from "../timing";
import { toNotch } from "./common";

// 4. Colour and archive. The glove picks a colour off a picture with the
// app's HUD beside it, and the colour drops into the notch. Close in: a click
// opens the panel, another its archive — the colour just picked first, then
// the scanned text and the decorated shot. The panel folds away, the hare
// looks out from behind the lid, and the camera returns.
export const ARCHIVE_FRAMES = 240;

const PICK: Cam = { x: 599, y: 330, s: 2.0 };
const CLOSE: Cam = { x: 599, y: 225, s: 2.8 };
const PICK_FROM = { x: 300, y: 172 };
const ARCHIVE_GLYPH = { x: panelX(GLYPH_AT.archive), y: GLYPH_Y };

export const Archive: React.FC = () => {
  const f = useCurrentFrame();
  const cam = camera(f, [
    [0, PICK],
    [64, PICK],
    [90, CLOSE],
    [206, CLOSE],
    [234, PICK],
  ]);

  const glove = track(f, [
    [0, REST.x, REST.y],
    [14, PICK_FROM.x, PICK_FROM.y],
    [36, PICK_AT.x, PICK_AT.y],
    [50, PICK_AT.x, PICK_AT.y],
    [86, NOTCH_X, 9],
    [94, NOTCH_X, 9],
    [110, ARCHIVE_GLYPH.x, ARCHIVE_GLYPH.y],
    [120, ARCHIVE_GLYPH.x, ARCHIVE_GLYPH.y],
    [138, stripTile(0).x, stripTile(0).y],
    [148, stripTile(0).x, stripTile(0).y],
    [164, stripTile(2).x, stripTile(2).y],
    [176, stripTile(2).x, stripTile(2).y],
    [200, REST.x, REST.y],
  ]);
  const press = Math.max(bump(f, 40, 48), bump(f, 94, 102), bump(f, 120, 128));

  const hud = seg(f, 12, 18, out) * (1 - seg(f, 54, 60));
  const copied = seg(f, 42, 46);
  const drop = seg(f, 46, 64, into);
  const dropAt = toNotch(drop, PICK_AT, { x: 470, y: 60 });

  const gulp = bump(f, 62, 74);
  const opened = seg(f, 98, 112, overshoot);
  const closing = seg(f, 178, 192);
  const tall = seg(f, 124, 138, overshoot) * (1 - seg(f, 176, 188));
  const panel = {
    w: lerp(84, PANEL_OPEN, opened) - (PANEL_OPEN - 84) * closing + 24 * gulp,
    h: lerp(15, ARCHIVE_H, tall) + 2 * gulp,
    glyphs: seg(f, 106, 116, out) * (1 - seg(f, 174, 182)),
    archive: seg(f, 124, 134),
    strip: seg(f, 130, 152, (t) => t),
  };

  const hareY = lerp(140, 100, seg(f, 188, 202, overshoot) * (1 - seg(f, 212, 224, into)));
  const hareBurst = seg(f, 192, 222, (t) => t);

  return (
    <Stage
      cam={cam}
      panel={panel}
      screen={<PhotoWindow />}
      over={
        <>
          <ColorHUD
            x={glove.x}
            y={glove.y}
            sample={(i, j) => photoColor(glove.x + i * PT, glove.y + j * PT)}
            copied={copied}
            opacity={hud}
          />
          {drop > 0 && drop < 1 && <circle cx={dropAt.x} cy={dropAt.y} r={lerp(6, 2.5, drop)} fill={PICKED} stroke="white" strokeWidth={1.5} />}
        </>
      }
      glove={{ ...glove, press }}
      hareY={hareY}
      hareScale={0.9}
      world={
        <>
          <Burst cx={SCREEN.x + NOTCH_X} cy={126} r0={38} r1={68} rays={3} from={178} to={226} width={CELL_NOTCH * 2.2} cell={CELL_NOTCH} p={hareBurst} seed={3} />
          <Burst cx={SCREEN.x + NOTCH_X} cy={126} r0={38} r1={68} rays={3} from={314} to={362} width={CELL_NOTCH * 2.2} cell={CELL_NOTCH} p={hareBurst} seed={6} />
          <Doodle s={star} color="#5CF2F5" x={SCREEN.x + NOTCH_X + 46} y={92} scale={0.42} p={seg(f, 196, 208, out)} opacity={1 - seg(f, 214, 220)} />
        </>
      }
    />
  );
};
