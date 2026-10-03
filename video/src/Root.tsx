import React from "react";
import { Composition } from "remotion";
import { HEIGHT, WIDTH } from "./stage";
import { FPS } from "./timing";
import { Capture, CAPTURE_FRAMES } from "./clips/Capture";
import { Editor, EDITOR_FRAMES } from "./clips/Editor";
import { Scan, SCAN_FRAMES } from "./clips/Scan";
import { Archive, ARCHIVE_FRAMES } from "./clips/Archive";

// Four short loops rather than one long clip: each sits by the README section
// it shows, and each is light enough to start playing straight away.
const CLIPS = [
  ["Capture", Capture, CAPTURE_FRAMES],
  ["Editor", Editor, EDITOR_FRAMES],
  ["Scan", Scan, SCAN_FRAMES],
  ["Archive", Archive, ARCHIVE_FRAMES],
] as const;

export const RemotionRoot: React.FC = () => (
  <>
    {CLIPS.map(([id, component, frames]) => (
      <Composition key={id} id={id} component={component} durationInFrames={frames} fps={FPS} width={WIDTH} height={HEIGHT} />
    ))}
  </>
);
