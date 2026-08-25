import { assertPlaybackEngine } from "./engine_contract.js";

function finiteNonNegative(value, fallback = 0) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : fallback;
}

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, value));
}

function assertVideo(video) {
  if (!video || typeof video !== "object") {
    throw new TypeError("MpegtsPlaybackEngine requires an HTMLMediaElement-like video");
  }

  return video;
}

function assertPlayer(player) {
  const required = ["attachMediaElement", "load", "unload", "destroy"];
  const missing = required.filter((method) => typeof player?.[method] !== "function");

  if (missing.length > 0) {
    throw new TypeError(
      `MpegtsPlaybackEngine player is missing required methods: ${missing.join(", ")}`,
    );
  }

  return player;
}

function normalizeSource(source) {
  if (typeof source === "string") {
    const url = source.trim();
    if (!url) throw new TypeError("MPEG-TS source requires a non-empty URL");
    return Object.freeze({ url, type: null, live: null });
  }

  if (!source || typeof source !== "object") {
    return Object.freeze({ url: null, type: null, live: null });
  }

  const url = typeof source.url === "string" ? source.url.trim() : null;
  if (source.url != null && !url) {
    throw new TypeError("MPEG-TS source requires a non-empty URL");
  }

  return Object.freeze({
    url,
    type: typeof source.type === "string" ? source.type : null,
    live:
      typeof source.isLive === "boolean"
        ? source.isLive
        : typeof source.live === "boolean"
          ? source.live
          : null,
  });
}

function readBufferedSeconds(video) {
  const ranges = video?.buffered;
  if (!ranges || ranges.length < 1) return 0;

  const current = finiteNonNegative(video.currentTime);
  for (let index = 0; index < ranges.length; index += 1) {
    const start = finiteNonNegative(ranges.start(index));
    const end = finiteNonNegative(ranges.end(index));
    if (current >= start && current <= end) return Math.max(0, end - current);
  }

  return 0;
}

function optionalSnapshot(value) {
  if (!value || typeof value !== "object") return null;
  return Object.freeze({ ...value });
}

/**
 * Stable application-facing wrapper around one mpegts.js player instance.
 *
 * StreamLoader owns construction and transport policy. This engine owns the
 * concrete attach/load/unload/destroy lifecycle and exposes the same playback
 * surface used by native and HLS engines.
 */
export class MpegtsPlaybackEngine {
  constructor({ video, player, source = null, resetSourceOnDestroy = false }) {
    this.video = assertVideo(video);
    this.player = assertPlayer(player);
    this.source = normalizeSource(source);
    this.resetSourceOnDestroy = resetSourceOnDestroy === true;
    this.attached = false;
    this.loaded = false;
    this.destroyed = false;
  }

  get client() {
    return this.player;
  }

  attach(video = this.video) {
    this.assertActive();
    this.video = assertVideo(video);

    if (!this.attached) {
      this.player.attachMediaElement(this.video);
      this.attached = true;
    }

    return this;
  }

  load(source = this.source) {
    this.assertActive();
    this.source = normalizeSource(source);
    this.attach();

    if (!this.loaded) {
      this.player.load();
      this.loaded = true;
    }

    return this.source;
  }

  reload(source = this.source) {
    this.assertActive();
    this.source = normalizeSource(source);

    if (this.loaded) {
      this.player.unload();
      this.loaded = false;
    }

    return this.load(this.source);
  }

  play() {
    this.assertActive();
    const result =
      typeof this.player.play === "function"
        ? this.player.play()
        : typeof this.video.play === "function"
          ? this.video.play()
          : (() => {
              throw new TypeError("MPEG-TS playback requires player.play() or video.play()");
            })();
    return result && typeof result.then === "function" ? result : Promise.resolve(result);
  }

  pause() {
    if (this.destroyed) return;
    if (typeof this.player.pause === "function") this.player.pause();
    else if (typeof this.video.pause === "function") this.video.pause();
    else throw new TypeError("MPEG-TS playback requires player.pause() or video.pause()");
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
    const normalized = clamp(Number(volume) || 0, 0, 1);
    this.video.volume = normalized;
    return normalized;
  }

  getCurrentTime() {
    return finiteNonNegative(this.video?.currentTime);
  }

  getDuration() {
    return finiteNonNegative(this.video?.duration);
  }

  isPlaying() {
    return this.video?.paused === false && this.video?.ended !== true;
  }

  on(event, handler) {
    this.assertActive();
    if (typeof this.player.on === "function") this.player.on(event, handler);
  }

  off(event, handler) {
    if (this.destroyed) return;
    if (typeof this.player.off === "function") this.player.off(event, handler);
  }

  snapshot() {
    const statistics = optionalSnapshot(this.player?.statisticsInfo);
    const mediaInfo = optionalSnapshot(this.player?.mediaInfo);

    return Object.freeze({
      engine: "mpegts",
      attached: this.attached,
      loaded: this.loaded,
      destroyed: this.destroyed,
      source: this.source,
      currentTime: this.getCurrentTime(),
      duration: this.getDuration(),
      paused: !this.isPlaying(),
      ended: this.video?.ended === true,
      live: this.source.live,
      bufferedSeconds: readBufferedSeconds(this.video),
      droppedFrames: finiteNonNegative(statistics?.droppedFrames ?? statistics?.droppedVideoFrames),
      decodedFrames: finiteNonNegative(statistics?.decodedFrames ?? statistics?.decodedVideoFrames),
      speed: finiteNonNegative(statistics?.speed),
      mediaInfo,
      statistics,
    });
  }

  destroy({ resetSource = this.resetSourceOnDestroy } = {}) {
    if (this.destroyed) return false;

    this.destroyed = true;
    const player = this.player;
    const video = this.video;

    try {
      if (this.loaded) player.unload();
    } finally {
      this.loaded = false;
    }

    try {
      if (this.attached && typeof player.detachMediaElement === "function") {
        player.detachMediaElement();
      }
    } finally {
      this.attached = false;
    }

    player.destroy();

    if (resetSource && video) {
      if (typeof video.removeAttribute === "function") video.removeAttribute("src");
      else video.src = "";
      video.load?.();
    }

    this.player = null;
    this.video = null;
    this.source = null;
    return true;
  }

  assertActive() {
    if (this.destroyed || !this.player) {
      throw new Error("MpegtsPlaybackEngine has been destroyed");
    }
  }
}

export function createMpegtsPlaybackEngine(options) {
  return assertPlaybackEngine(new MpegtsPlaybackEngine(options), {
    name: "mpegts",
  });
}
