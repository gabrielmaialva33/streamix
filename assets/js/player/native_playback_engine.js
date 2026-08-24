import { assertPlaybackEngine, ENGINE_ID } from "./engine_contract.js";
import { createMediaElementEngine } from "./media_element_engine.js";

const PRELOAD_VALUES = new Set(["none", "metadata", "auto"]);

function finiteNonNegative(value, fallback = 0) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : fallback;
}

function optionalBoolean(value) {
  return typeof value === "boolean" ? value : null;
}

function optionalText(value) {
  if (typeof value !== "string") return null;
  const normalized = value.trim();
  return normalized.length > 0 ? normalized : null;
}

function assertNativeVideo(video) {
  if (!video || typeof video.load !== "function") {
    throw new TypeError(
      "NativePlaybackEngine requires an HTMLMediaElement-like object with load()",
    );
  }
}

function normalizeSource(source, options = {}) {
  const candidate = typeof source === "string" ? { url: source } : source;

  if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) {
    throw new TypeError("Native playback source must be a URL or source object");
  }

  const url = optionalText(candidate.url ?? candidate.src);
  if (!url) {
    throw new TypeError("Native playback source requires a non-empty URL");
  }

  const preloadCandidate = options.preload ?? candidate.preload;
  const preload = PRELOAD_VALUES.has(preloadCandidate) ? preloadCandidate : null;

  return Object.freeze({
    url,
    type: optionalText(options.type ?? candidate.type),
    preload,
    crossOrigin: optionalText(options.crossOrigin ?? candidate.crossOrigin),
    playsInline: optionalBoolean(options.playsInline ?? candidate.playsInline),
    autoplay: optionalBoolean(options.autoplay ?? candidate.autoplay),
    muted: optionalBoolean(options.muted ?? candidate.muted),
    startTime: finiteNonNegative(options.startTime ?? candidate.startTime),
  });
}

/**
 * Concrete native browser engine backed by the shared HTML media element.
 *
 * This class owns native source assignment and teardown. HLS.js and mpegts.js
 * continue to use `MediaElementEngine` with their transport lifecycle injected,
 * so adopting this engine does not change those paths.
 */
export class NativePlaybackEngine {
  constructor({
    video,
    beforePause = () => undefined,
    beforeSeek = () => undefined,
    afterSeek = () => undefined,
    resetSourceOnDestroy = true,
  } = {}) {
    assertNativeVideo(video);

    this.id = ENGINE_ID.NATIVE;
    this.video = video;
    this.source = null;
    this.destroyed = false;
    this.resetSourceOnDestroy = resetSourceOnDestroy !== false;
    this.pendingMetadataHandler = null;
    this.media = createMediaElementEngine({
      video,
      beforePause,
      beforeSeek,
      afterSeek,
    });
  }

  load(source, options = {}) {
    this.assertActive();
    const normalized = normalizeSource(source, options);

    this.clearPendingMetadataSeek();
    this.applySourceOptions(normalized);
    this.source = normalized;
    this.video.src = normalized.url;
    this.video.load();
    this.scheduleInitialSeek(normalized.startTime);

    return normalized;
  }

  play() {
    this.assertActive();
    return this.media.play();
  }

  pause() {
    this.assertActive();
    return this.media.pause();
  }

  seek(seconds) {
    this.assertActive();
    return this.media.seek(seconds);
  }

  setVolume(volume) {
    this.assertActive();
    return this.media.setVolume(volume);
  }

  getCurrentTime() {
    this.assertActive();
    return this.media.getCurrentTime();
  }

  getDuration() {
    this.assertActive();
    return this.media.getDuration();
  }

  isPlaying() {
    this.assertActive();
    return this.media.isPlaying();
  }

  on(event, handler) {
    this.assertActive();
    return this.media.on(event, handler);
  }

  off(event, handler) {
    if (this.destroyed || !this.media) return;
    return this.media.off(event, handler);
  }

  snapshot() {
    if (this.destroyed || !this.video) {
      return Object.freeze({
        engine: this.id,
        attached: false,
        destroyed: true,
        source: null,
        currentTime: 0,
        duration: 0,
        paused: true,
      });
    }

    return Object.freeze({
      engine: this.id,
      attached: true,
      destroyed: false,
      source: this.source,
      currentTime: this.media.getCurrentTime(),
      duration: this.media.getDuration(),
      paused: !this.media.isPlaying(),
      ended: this.video.ended === true,
      muted: this.video.muted === true,
      volume: finiteNonNegative(this.video.volume, 1),
      playbackRate: finiteNonNegative(this.video.playbackRate, 1),
      readyState: finiteNonNegative(this.video.readyState),
      networkState: finiteNonNegative(this.video.networkState),
    });
  }

  destroy({ resetSource = this.resetSourceOnDestroy } = {}) {
    if (this.destroyed) return false;

    const video = this.video;
    this.clearPendingMetadataSeek();

    try {
      this.media.pause();
    } catch {
      // Cleanup remains best-effort when the browser has already detached media.
    }

    if (resetSource) {
      if (typeof video.removeAttribute === "function") video.removeAttribute("src");
      else video.src = "";

      try {
        video.load();
      } catch {
        // Some embedded browsers reject load() while the document is unloading.
      }
    }

    try {
      this.media.destroy();
    } finally {
      this.destroyed = true;
      this.source = null;
      this.video = null;
      this.media = null;
    }

    return true;
  }

  applySourceOptions(source) {
    if (source.preload !== null) this.video.preload = source.preload;
    if (source.crossOrigin !== null) this.video.crossOrigin = source.crossOrigin;
    if (source.playsInline !== null) this.video.playsInline = source.playsInline;
    if (source.autoplay !== null) this.video.autoplay = source.autoplay;
    if (source.muted !== null) this.video.muted = source.muted;
  }

  scheduleInitialSeek(startTime) {
    if (startTime <= 0) return;

    if (finiteNonNegative(this.video.readyState) >= 1) {
      this.media.seek(startTime);
      return;
    }

    if (typeof this.video.addEventListener !== "function") {
      this.media.seek(startTime);
      return;
    }

    const handler = () => {
      if (this.pendingMetadataHandler !== handler) return;
      this.clearPendingMetadataSeek();
      if (!this.destroyed) this.media.seek(startTime);
    };

    this.pendingMetadataHandler = handler;
    this.video.addEventListener("loadedmetadata", handler, { once: true });
  }

  clearPendingMetadataSeek() {
    if (!this.pendingMetadataHandler || !this.video) return;

    this.video.removeEventListener?.("loadedmetadata", this.pendingMetadataHandler);
    this.pendingMetadataHandler = null;
  }

  assertActive() {
    if (this.destroyed || !this.video || !this.media) {
      throw new Error("Native playback engine has been destroyed");
    }
  }
}

export function createNativePlaybackEngine(options) {
  return assertPlaybackEngine(new NativePlaybackEngine(options), {
    name: "NativePlaybackEngine",
  });
}
