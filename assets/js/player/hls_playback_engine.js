import { assertPlaybackEngine } from "./engine_contract.js";

function finiteNonNegative(value, fallback = 0) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : fallback;
}

function optionalFinite(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, value));
}

function assertVideo(video) {
  if (!video || typeof video.play !== "function" || typeof video.pause !== "function") {
    throw new TypeError("HLS playback engine requires an HTMLMediaElement-like video");
  }

  return video;
}

function assertHlsClient(hls) {
  if (!hls || typeof hls !== "object") {
    throw new TypeError("HLS playback engine requires an hls.js client");
  }

  const missing = ["loadSource", "attachMedia", "stopLoad", "startLoad", "destroy"].filter(
    (method) => typeof hls[method] !== "function",
  );

  if (missing.length > 0) {
    throw new TypeError(`hls.js client is missing methods: ${missing.join(", ")}`);
  }

  return hls;
}

function normalizeSource(source) {
  const candidate = typeof source === "string" ? { url: source } : source;
  const url = candidate?.url ?? candidate?.src;

  if (typeof url !== "string" || url.trim() === "") {
    throw new TypeError("HLS playback source requires a non-empty URL");
  }

  return Object.freeze({ url: url.trim() });
}

function safeRead(read, fallback = null) {
  try {
    return read();
  } catch {
    return fallback;
  }
}

/**
 * Contract adapter around one hls.js instance.
 *
 * This engine owns source loading, media attachment, soft reload, controls,
 * snapshots, and deterministic teardown. Recovery and cross-engine fallback
 * intentionally remain in StreamLoader and VideoPlayer during this migration.
 */
export class HlsPlaybackEngine {
  constructor({ video, hls, resetSourceOnDestroy = false } = {}) {
    this.video = assertVideo(video);
    this.hls = assertHlsClient(hls);
    this.resetSourceOnDestroy = resetSourceOnDestroy === true;
    this.source = null;
    this.destroyed = false;
    this.attached = false;
  }

  get client() {
    return this.hls;
  }

  attach() {
    this.assertActive();

    if (!this.attached) {
      this.hls.attachMedia(this.video);
      this.attached = true;
    }

    return this;
  }

  load(source) {
    this.assertActive();
    const normalized = normalizeSource(source);

    this.hls.loadSource(normalized.url);
    this.attach();
    this.source = normalized;

    return this.hls;
  }

  reload(source, { startPosition = -1 } = {}) {
    this.assertActive();
    const normalized = normalizeSource(source);
    const position = Number.isFinite(Number(startPosition)) ? Number(startPosition) : -1;

    this.hls.stopLoad();
    this.hls.loadSource(normalized.url);
    this.hls.startLoad(position);
    this.source = normalized;

    return this.hls;
  }

  play() {
    this.assertActive();
    const result = this.video.play();
    return result && typeof result.then === "function" ? result : Promise.resolve(result);
  }

  pause() {
    this.assertActive();
    this.video.pause();
  }

  seek(seconds) {
    this.assertActive();
    const duration = this.getDuration();
    const maximum = duration > 0 ? duration : Number.MAX_SAFE_INTEGER;
    const target = clamp(finiteNonNegative(seconds), 0, maximum);

    this.video.currentTime = target;
    return target;
  }

  setVolume(volume) {
    this.assertActive();
    const normalized = clamp(finiteNonNegative(volume), 0, 1);
    this.video.volume = normalized;
    return normalized;
  }

  getCurrentTime() {
    this.assertActive();
    return finiteNonNegative(this.video.currentTime);
  }

  getDuration() {
    this.assertActive();
    return finiteNonNegative(this.video.duration);
  }

  isPlaying() {
    this.assertActive();
    return this.video.paused === false && this.video.ended !== true;
  }

  on(event, handler) {
    this.assertActive();
    this.hls.on?.(event, handler);
  }

  off(event, handler) {
    if (this.destroyed || !this.hls) return;
    this.hls.off?.(event, handler);
  }

  snapshot() {
    const hls = this.hls;
    const video = this.video;

    return Object.freeze({
      engine: "hls",
      attached: this.attached,
      destroyed: this.destroyed,
      source: this.source,
      currentTime: finiteNonNegative(video?.currentTime),
      duration: finiteNonNegative(video?.duration),
      paused: video?.paused !== false,
      ended: video?.ended === true,
      currentLevel: hls ? safeRead(() => hls.currentLevel, -1) : -1,
      loadLevel: hls ? safeRead(() => hls.loadLevel, -1) : -1,
      autoLevelEnabled: hls ? safeRead(() => hls.autoLevelEnabled === true, false) : false,
      bandwidthEstimate: hls ? optionalFinite(safeRead(() => hls.bandwidthEstimate)) : null,
      latency: hls ? optionalFinite(safeRead(() => hls.latency)) : null,
      targetLatency: hls ? optionalFinite(safeRead(() => hls.targetLatency)) : null,
      liveSyncPosition: hls ? optionalFinite(safeRead(() => hls.liveSyncPosition)) : null,
    });
  }

  destroy({ resetSource = this.resetSourceOnDestroy } = {}) {
    if (this.destroyed) return false;

    const hls = this.hls;
    const video = this.video;

    this.destroyed = true;
    this.hls = null;
    this.source = null;
    this.attached = false;

    hls.destroy();

    if (resetSource && video) {
      if (typeof video.removeAttribute === "function") video.removeAttribute("src");
      else video.src = "";
      video.load?.();
    }

    return true;
  }

  assertActive() {
    if (this.destroyed) throw new Error("HLS playback engine has been destroyed");
    if (!this.hls) throw new Error("HLS playback engine has no active hls.js client");
  }
}

export function createHlsPlaybackEngine(options) {
  return assertPlaybackEngine(new HlsPlaybackEngine(options), { name: "hls" });
}
