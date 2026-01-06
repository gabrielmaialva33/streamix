import { WebGlCoreRenderer, SdfTextRenderer } from "@lightningjs/renderer/webgl";
import { Inspector } from "@lightningjs/renderer/inspector";
import { DeviceCommon } from "./device";

export const config = {
  name: "common",
  quality: {
    image: {
      ratio: 1,
      quality: 80,
    },
  },
  timing: {
    hero: 500,
  },
  lightning: {
    debug: false,
    focusDebug: false,
    fontSettings: { fontFamily: "Roboto", color: 0xffffffff, fontSize: 40 },
    animationSettings: { easing: "ease-in-out", duration: 250 },
    rendererOptions: {
      appHeight: 1080,
      appWidth: 1920,
      // Disable image workers to avoid CORS issues with cross-origin images
      numImageWorkers: 0,
      fontEngines: [SdfTextRenderer],
      renderEngine: WebGlCoreRenderer,
      inspector: import.meta.env.DEV ? Inspector : undefined,
      // 720p = 0.666667, 1080p = 1, 1440p = 1.5, 2160p = 2
      deviceLogicalPixelRatio: 1,
      devicePhysicalPixelRatio: 1,
      // Increase to preload images coming from offscreen
      boundsMargin: 500,
      // Transparent background for video playback (allows HTML5 video to show through)
      clearColor: 0x00000000,
      // Texture Memory Manager settings for TV devices
      textureMemory: {
        // Reasonable threshold (default is 124MB, TV can handle ~100MB)
        criticalThreshold: 100e6, // 100MB - triggers cleanup
        // Target 60% of critical after cleanup (60MB)
        targetThresholdLevel: 0.6,
        // Cleanup interval (default 5000ms)
        cleanupInterval: 5000, // 5 seconds
        // Debug logging in dev mode only
        debugLogging: import.meta.env.DEV,
      },
    },
  },
  keys: {
    Back: ["b", 66],
    Left: ["ArrowLeft", 37],
    Right: ["ArrowRight", 39],
    Up: ["ArrowUp", 38],
    Down: ["ArrowDown", 40],
    Enter: ["Enter", 13],
    Play: ["p", 80],
    Pause: ["a", 65],
    Menu: ["m"],
    PlayPause: ["t", 84],
    FastForward: ["f", 70],
    FastForward10: ["d", 68],
    Rewind: ["r", 82],
    Rewind10: ["e", 69],
    Stop: ["s", 83],
    Key0: ["0", 96, 48],
    Key1: ["1", 97, 49],
    Key2: ["2", 98, 50],
    Key3: ["3", 99, 51],
    Key4: ["4", 100, 52],
    Key5: ["5", 101, 53],
    Key6: ["6", 102, 54],
    Key7: ["7", 103, 55],
    Key8: ["8", 104, 56],
    Key9: ["9", 105, 57],
  },
  keyHoldOptions: {
    userKeyHoldMap: {
      EnterHold: ["Enter", 13],
      BackHold: ["b", 66],
    },
    holdThreshold: 1000,
  },
  initialize: function (): Promise<DeviceCommon> {
    return DeviceCommon.initialize();
  },
};
