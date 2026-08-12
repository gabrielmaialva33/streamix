import { playerLogger as log } from "../core/logger.js";

export function createLazyModuleLoader({ label, load, select = (module) => module, logger = log }) {
  if (typeof load !== "function") {
    throw new TypeError("Lazy module loader requires a load function");
  }

  let loaded = false;
  let value;
  let pending;

  return () => {
    if (loaded) return Promise.resolve(value);

    pending ||= Promise.resolve()
      .then(() => {
        logger.debug(`Lazy loading ${label} module...`);
        return load();
      })
      .then((module) => {
        value = select(module);
        loaded = true;
        logger.debug(`${label} module loaded`);
        return value;
      })
      .catch((error) => {
        pending = null;
        throw error;
      });

    return pending;
  };
}

export const loadAVPlayer = createLazyModuleLoader({
  label: "AVPlayer",
  load: () => import("../media/avplayer_wrapper.js"),
  select: ({ AVPlayerWrapper, detectAudioIssue }) => ({ AVPlayerWrapper, detectAudioIssue }),
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
