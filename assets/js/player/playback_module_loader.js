import { memoizeImport } from "../core/async_primitives.js";
import { playerLogger as log } from "../core/logger.js";

export function createLazyModuleLoader({ label, load, select = (module) => module, logger = log }) {
  if (typeof load !== "function") {
    throw new TypeError("Lazy module loader requires a load function");
  }

  return memoizeImport(() => {
    logger.debug(`Lazy loading ${label} module...`);
    return Promise.resolve(load()).then((module) => {
      const value = select(module);
      logger.debug(`${label} module loaded`);
      return value;
    });
  });
}

export const loadAVPlayer = createLazyModuleLoader({
  label: "AVPlayer",
  load: () => import("../media/avplayer_wrapper.js"),
  select: ({ AVPlayerWrapper, detectAudioIssue, preloadAVPlayerRuntime }) => ({
    AVPlayerWrapper,
    detectAudioIssue,
    preloadAVPlayerRuntime,
  }),
});

export const loadAvbridge = createLazyModuleLoader({
  label: "avbridge",
  load: () => import("../media/avbridge_wrapper.js"),
  select: ({ AvbridgeWrapper }) => ({ AvbridgeWrapper }),
});

export const loadH265web = createLazyModuleLoader({
  label: "h265web",
  load: () => import("../media/h265web_wrapper.js"),
  select: ({ H265webWrapper }) => ({ H265webWrapper }),
});
