import { getHls, getMpegts } from "../media/player_libs.js";
import { loadAVPlayer } from "./playback_module_loader.js";

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
    avplayer: loadAVPlayer,
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
    const engine = ["hls", "m3u8"].includes(type)
      ? "hls"
      : ["ts", "xtream", "flv"].includes(type)
        ? "mpegts"
        : dataset.sourceType === "gindex" && type !== "mp4"
          ? "avplayer"
          : "native";
    if (!pending.has(engine)) {
      pending.set(
        engine,
        Promise.resolve()
          .then(() => loaders[engine]())
          .catch(() => pending.delete(engine)),
      );
    }
    return pending.get(engine);
  };
}

const warmEngine = createEngineWarmup();

/** Ephemeral same-document intent only: no URLs/titles are persisted or requested. */
export function installPlaybackIntent({
  documentRef = globalThis.document,
  now = nowDefault,
  warm = warmEngine,
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
    };
  };
  documentRef.addEventListener("pointerover", warmOnIntent, true);
  documentRef.addEventListener("focusin", warmOnIntent, true);
  documentRef.addEventListener("click", click, true);
  return () => {
    documentRef.removeEventListener("pointerover", warmOnIntent, true);
    documentRef.removeEventListener("focusin", warmOnIntent, true);
    documentRef.removeEventListener("click", click, true);
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
  return { startedAt: selected.startedAt, cover: selected.cover };
}
