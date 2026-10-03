import { Config } from "@remotion/cli/config";

// PNG frames: the pixel pattern is all hard edges, and JPEG smears them
// before the WebP encoder ever sees them.
Config.setVideoImageFormat("png");
Config.setOverwriteOutput(true);
Config.setCodec("h264");
