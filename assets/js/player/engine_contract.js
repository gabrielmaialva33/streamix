export const ENGINE_ID = Object.freeze({
  NATIVE: "native",
  HLS: "hls",
  MPEGTS: "mpegts",
  AVPLAYER: "avplayer",
  AVBRIDGE: "avbridge",
  H265WEB: "h265web",
  UNKNOWN: "unknown",
});

export const ENGINE_SELECTION = Object.freeze({
  NATIVE: "native",
  HLS_JS: "hls-js",
  MPEGTS: "mpegts",
  MPEGTS_FLV: "mpegts-flv",
  AVPLAYER: "avplayer",
  AVBRIDGE: "avbridge",
  H265WEB: "h265web",
  FLV_UNSUPPORTED: "flv-unsupported",
});

export const PLAYBACK_STATE = Object.freeze({
  IDLE: "idle",
  SELECTING_SOURCE: "selecting_source",
  LOADING: "loading",
  READY: "ready",
  PLAYING: "playing",
  STALLED: "stalled",
  RECOVERING: "recovering",
  ENDED: "ended",
  TERMINAL: "terminal",
  DESTROYED: "destroyed",
});

export const ENGINE_EVENT = Object.freeze({
  METADATA: "metadata",
  READY: "ready",
  PLAYING: "playing",
  STALLED: "stalled",
  RECOVERED: "recovered",
  ENDED: "ended",
  ERROR: "error",
  FATAL_ERROR: "fatal_error",
  TRACK_CHANGED: "track_changed",
});

const RUNTIME_ENGINE_IDS = new Set(Object.values(ENGINE_ID));
const ENGINE_SELECTIONS = new Set(Object.values(ENGINE_SELECTION));
const SELECTION_TO_ENGINE_ID = new Map([
  [ENGINE_SELECTION.NATIVE, ENGINE_ID.NATIVE],
  [ENGINE_SELECTION.HLS_JS, ENGINE_ID.HLS],
  [ENGINE_SELECTION.MPEGTS, ENGINE_ID.MPEGTS],
  [ENGINE_SELECTION.MPEGTS_FLV, ENGINE_ID.MPEGTS],
  [ENGINE_SELECTION.AVPLAYER, ENGINE_ID.AVPLAYER],
  [ENGINE_SELECTION.AVBRIDGE, ENGINE_ID.AVBRIDGE],
  [ENGINE_SELECTION.H265WEB, ENGINE_ID.H265WEB],
  [ENGINE_SELECTION.FLV_UNSUPPORTED, ENGINE_ID.UNKNOWN],
]);

export function isEngineId(value) {
  return typeof value === "string" && RUNTIME_ENGINE_IDS.has(value);
}

export function isEngineSelection(value) {
  return typeof value === "string" && ENGINE_SELECTIONS.has(value);
}

export function normalizeEngineId(value) {
  if (isEngineId(value)) return value;
  return SELECTION_TO_ENGINE_ID.get(value) ?? ENGINE_ID.UNKNOWN;
}

export function assertEngineSelection(value) {
  if (!isEngineSelection(value)) {
    throw new TypeError(`Unknown playback engine selection: ${String(value)}`);
  }

  return value;
}

export function engineIdFromRuntime(runtime = {}) {
  if (runtime.usingAVPlayer) return ENGINE_ID.AVPLAYER;
  if (runtime.usingH265web) return ENGINE_ID.H265WEB;
  if (runtime.usingAvbridge) return ENGINE_ID.AVBRIDGE;
  if (isEngineId(runtime.mediaElementEngine?.id)) {
    return runtime.mediaElementEngine.id;
  }

  try {
    if (runtime.streamLoader?.getHls?.()) return ENGINE_ID.HLS;
    if (runtime.streamLoader?.getMpegtsPlayer?.()) return ENGINE_ID.MPEGTS;
  } catch {
    // A runtime being torn down must still expose a stable, non-throwing identity.
  }

  return ENGINE_ID.NATIVE;
}
