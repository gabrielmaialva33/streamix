// avbridge_wrapper.js
//
// Thin adapter that lets us drive Keishi Hattori's `avbridge`
// (https://github.com/keishi/avbridge) with the same surface
// `AVPlayerWrapper` exposes — `load`, `play`, `pause`, `seek`,
// `getCurrentTime`, `getDuration`, `destroy`, and a tiny event bus.
//
// We use this only for **GIndex 4K HEVC** content. Why bother when
// `AVPlayerWrapper` (libmedia) already plays it?
//
//   * libmedia decodes HEVC in WASM software → 60-90% CPU on a 4K
//     2160p stream, painful on integrated graphics laptops.
//   * avbridge prefers `WebCodecs` hardware decode (Chrome / Edge),
//     remuxes MKV → fMP4, and falls back to libav.js only when the
//     browser cannot accelerate. So on a Chrome desktop with a HEVC
//     hardware path, the decode lands on the GPU → <10% CPU.
//
// We keep `AVPlayerWrapper` as the universal fallback. The hook in
// `video_player.js` tries avbridge first for GIndex MKV/HEVC, and
// falls back to AVPlayerWrapper on any init error.

import { avplayerLogger as log } from "../core/logger";

export class AvbridgeWrapper {
  constructor(options = {}) {
    this.video = options.video || options.videoElement;
    if (!this.video) {
      throw new Error("AvbridgeWrapper requires { video: HTMLVideoElement }");
    }
    this.player = null;
    this.initialStrategy = options.initialStrategy || null;
    this.events = new Map();
  }

  /**
   * Lazily import the avbridge bundle and create the underlying player.
   * Called once from `playWithAvbridge` in the LiveView hook.
   */
  async init() {
    const mod = await import("avbridge");
    this._mod = mod;
    log.debug("[Avbridge] module loaded");
  }

  /**
   * Load + start playback. Mirrors the AVPlayerWrapper.load contract so
   * the hook can swap engines without branching on which one it has.
   */
  async load(url, options = {}) {
    if (!this._mod) await this.init();

    const opts = {
      // avbridge MediaInput accepts `File | Blob | string | URL |
      // ArrayBuffer | Uint8Array`. Passing `{ url }` is the libmedia
      // shape and trips the probe with `unsupported source type`.
      source: url,
      target: this.video,
      // Browser CORS is already handled by the upstream proxy
      // (`gindex.mahina.cloud` adds permissive CORS headers); leave
      // requestInit unset so avbridge issues vanilla GETs.
    };
    if (this.initialStrategy) opts.initialStrategy = this.initialStrategy;
    if (options.startTime && options.startTime > 0) opts.startTime = options.startTime;

    this.player = await this._mod.createPlayer(opts);
    log.debug("[Avbridge] player created", {
      url,
      strategy: this.player.getDiagnostics?.()?.strategy,
    });

    // Forward the events the hook actually consumes. avbridge emits
    // through its own emitter; we re-emit on a Map-backed bus that
    // matches the AVPlayerWrapper API.
    if (typeof this.player.on === "function") {
      this.player.on("playing", () => this._emit("playing"));
      this.player.on("paused", () => this._emit("paused"));
      this.player.on("ended", () => this._emit("ended"));
      this.player.on("error", (err) => this._emit("error", err));
      this.player.on("strategy-changed", (info) => {
        log.debug("[Avbridge] strategy escalation", info);
        this._emit("strategy-changed", info);
      });
    }
  }

  async play() {
    if (!this.player) throw new Error("AvbridgeWrapper: not loaded");
    return this.player.play();
  }

  pause() {
    return this.player?.pause();
  }

  async seek(time) {
    return this.player?.seek(time);
  }

  getCurrentTime() {
    return this.player?.getCurrentTime?.() ?? this.video.currentTime ?? 0;
  }

  getDuration() {
    return this.player?.getDuration?.() ?? this.video.duration ?? 0;
  }

  setVolume(volume) {
    if (this.video) this.video.volume = Math.max(0, Math.min(1, volume));
  }

  isPlaying() {
    return !!this.video && !this.video.paused && !this.video.ended;
  }

  /**
   * avbridge does not expose track selection in the same shape as
   * AVPlayerWrapper. We surface only the audio/subtitle indices the
   * underlying player reports; the UI's track picker can fall through
   * to native `<video>.audioTracks` for MP4 remux paths.
   */
  async getAudioTracks() {
    const diag = this.player?.getDiagnostics?.();
    return diag?.audioTracks ?? [];
  }

  async getSubtitleTracks() {
    const diag = this.player?.getDiagnostics?.();
    return diag?.subtitleTracks ?? [];
  }

  async selectAudioTrack(id) {
    return this.player?.setAudioTrack?.(id);
  }

  async selectSubtitleTrack(id) {
    return this.player?.setSubtitleTrack?.(id);
  }

  async destroy() {
    try {
      await this.player?.destroy?.();
    } catch (err) {
      log.warn("[Avbridge] destroy threw", err);
    } finally {
      this.player = null;
      this.events.clear();
    }
  }

  on(event, handler) {
    const list = this.events.get(event) || [];
    list.push(handler);
    this.events.set(event, list);
  }

  off(event, handler) {
    const list = this.events.get(event);
    if (!list) return;
    this.events.set(
      event,
      list.filter((h) => h !== handler),
    );
  }

  _emit(event, ...args) {
    for (const h of this.events.get(event) || []) {
      try {
        h(...args);
      } catch (err) {
        log.warn(`[Avbridge] handler for ${event} threw`, err);
      }
    }
  }
}

export default AvbridgeWrapper;
