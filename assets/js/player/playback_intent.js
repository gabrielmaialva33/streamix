import { getHls, getMpegts } from "../media/player_libs.js";
import { loadAVPlayer } from "./playback_module_loader.js";
import { getRecommendedPlayer, playerRecommendationKey } from "./player_preferences.js";

const PLAY_SELECTOR =
  'a[href*="/watch/"],[phx-click^="play_"],[phx-click="play"],[data-action="play"],[data-player-play]';
const nowDefault = () => globalThis.performance?.now?.() ?? Date.now();
let intent = null;

function contextFor(element) {
  return element?.closest?.("[data-stream-type],[data-source-type],[data-content-id]") || element;
}

export function createEngineWarmup({
  loaders = {
    hls: getHls,
    mpegts: getMpegts,
    avplayer: async (dataset) => {
      const { preloadAVPlayerRuntime } = await loadAVPlayer();
      await preloadAVPlayerRuntime({
        stream_type: dataset.streamType,
        source_type: dataset.sourceType,
      });
    },
    native: () => import("./native_playback_engine.js"),
  },
} = {}) {
  const pending = new Map();
  return (element) => {
    const dataset = contextFor(element)?.dataset || {};
    const href = element?.getAttribute?.("href") || "";
    const type =
      dataset.streamType ||
      (href.includes("/live_channel/") ? "ts" : dataset.sourceType === "gindex" ? "mkv" : "mp4");
    const providerId =
      element?.closest?.("[data-provider-id]")?.dataset?.providerId || dataset.providerId;
    const recommended = getRecommendedPlayer(
      playerRecommendationKey({ providerId, streamType: type }),
    );
    const engine = ["hls", "m3u8"].includes(type)
      ? "hls"
      : ["ts", "xtream", "flv"].includes(type)
        ? "mpegts"
        : recommended === "avplayer" || (dataset.sourceType === "gindex" && type !== "mp4")
          ? "avplayer"
          : "native";
    if (!pending.has(engine)) {
      pending.set(
        engine,
        Promise.resolve()
          .then(() => loaders[engine](dataset))
          .catch(() => pending.delete(engine)),
      );
    }
    return pending.get(engine);
  };
}

const warmEngine = createEngineWarmup();

const WARM_SELECTOR = "[data-playback-warm]";

const onIdle = (callback, windowRef = globalThis) =>
  typeof windowRef.requestIdleCallback === "function"
    ? windowRef.requestIdleCallback(callback, { timeout: 2_000 })
    : windowRef.setTimeout(callback, 200);

/**
 * Warms the engine for a page's main play button once the page is idle.
 *
 * Hover and focus warm on desktop, but a phone never hovers: the first tap
 * paid the whole AVPlayer runtime load (scripts and WASM decoders). A title
 * page marks its "Assistir" button with data-playback-warm and its stream
 * hints, so the predicted engine is ready before the tap. Speculative work is
 * still skipped on Save-Data or a slow connection (see preloadAVPlayerRuntime).
 */
export function warmPrimaryPlayback({
  documentRef = globalThis.document,
  warm = warmEngine,
  schedule = onIdle,
} = {}) {
  const element = documentRef?.querySelector?.(WARM_SELECTOR);
  if (!element) return false;
  schedule(() => {
    if (element.isConnected !== false) void warm(element);
  });
  return true;
}

/** Ephemeral same-document intent only: no URLs/titles are persisted or requested. */
export function installPlaybackIntent({
  documentRef = globalThis.document,
  windowRef = globalThis,
  now = nowDefault,
  warm = warmEngine,
  schedule = onIdle,
} = {}) {
  const find = (event) => event.target?.closest?.(PLAY_SELECTOR);
  const warmOnIntent = (event) => {
    const element = find(event);
    if (element) void warm(element);
  };
  const click = (event) => {
    if (event.button > 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)
      return;
    const element = find(event);
    if (!element || element.closest?.("#video-player-container")) return;
    const context = contextFor(element);
    const coverContext =
      element.closest?.("[data-cover],.content-preview,[data-content-id]") || context;
    intent = {
      startedAt: now(),
      contentId: context?.dataset?.contentId || element.getAttribute?.("phx-value-id") || null,
      cover: coverContext?.dataset?.cover || coverContext?.querySelector?.("img")?.src || null,
      providerId:
        element.closest?.("[data-provider-id]")?.dataset?.providerId ||
        context?.dataset?.providerId ||
        null,
    };
  };
  const warmPage = () => warmPrimaryPlayback({ documentRef, warm, schedule });
  documentRef.addEventListener("pointerover", warmOnIntent, true);
  documentRef.addEventListener("focusin", warmOnIntent, true);
  documentRef.addEventListener("click", click, true);
  // LiveView navigation swaps pages without a load event.
  windowRef?.addEventListener?.("phx:page-loading-stop", warmPage);
  warmPage();
  return () => {
    documentRef.removeEventListener("pointerover", warmOnIntent, true);
    documentRef.removeEventListener("focusin", warmOnIntent, true);
    documentRef.removeEventListener("click", click, true);
    windowRef?.removeEventListener?.("phx:page-loading-stop", warmPage);
    intent = null;
  };
}

export function consumePlaybackIntent({ contentId, now = nowDefault } = {}) {
  const selected = intent;
  intent = null;
  if (
    !selected ||
    now() - selected.startedAt > 30_000 ||
    (contentId && selected.contentId && String(contentId) !== String(selected.contentId))
  )
    return null;
  return {
    startedAt: selected.startedAt,
    cover: selected.cover,
    ...(selected.providerId ? { providerId: selected.providerId } : {}),
  };
}
