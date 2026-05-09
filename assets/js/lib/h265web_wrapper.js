// h265web_wrapper.js
//
// Adapter for numberwolf/h265web.js (https://github.com/numberwolf/h265web.js)
// — built against the public PRO docs at
// https://h265web.com/markdown-docs/get-started.php.
//
// Same surface as `AVPlayerWrapper` so `video_player.js` can swap engines
// without branching on which one it has.
//
// Why h265web.js?
//   * libmedia (current AVPlayer) decodes HEVC in WASM software → on a
//     2160p Atmos stream it lands at 60-90% CPU on the laptops we see
//     in the field; seeks stutter, audio glitches.
//   * h265web.js exposes a `webcodec_hevc` core that hands the
//     bitstream to `VideoDecoder`, which routes the work to GPU. On a
//     Chrome desktop with HEVC hardware (Intel 11th-gen+, Apple
//     Silicon, recent NVIDIA) the same stream lands well under 10% CPU.
//
// Asset layout: the SDK's six runtime files live in
// `priv/static/vendor/h265web/` (served by Phoenix as
// `/vendor/h265web/...`). The npm package only ships a thin loader so
// we vendored them directly. Override the base URL via the
// `data-h265web-base-url` attribute on the player container — useful
// for self-hosting on a separate origin.

import { avplayerLogger as log } from "./logger";

const DEFAULT_BASE_URL = "/vendor/h265web/";
const SCRIPT_NAME = "h265web.js";
const SDK_GLOBALS = ["H265webjsPlayer", "new265webjs"];

let _scriptPromise = null;

/**
 * Inject `h265web.js` exactly once per page. The library installs its
 * factory as a window global — there is no ESM build, so a `<script>`
 * tag is the supported integration. Subsequent wrappers reuse the
 * cached promise.
 */
function loadH265webScript(baseUrl) {
  if (typeof window === "undefined") {
    return Promise.reject(new Error("h265web requires a browser context"));
  }
  if (resolveFactory()) return Promise.resolve();
  if (_scriptPromise) return _scriptPromise;

  const url = baseUrl.replace(/\/?$/, "/") + SCRIPT_NAME;
  _scriptPromise = new Promise((resolve, reject) => {
    const s = document.createElement("script");
    s.src = url;
    s.async = true;
    s.onload = () => {
      if (resolveFactory()) resolve();
      else reject(new Error(`h265web loaded but no factory exported`));
    };
    s.onerror = () => {
      _scriptPromise = null;
      reject(new Error(`Failed to load h265web from ${url}`));
    };
    document.head.appendChild(s);
  });
  return _scriptPromise;
}

function resolveFactory() {
  for (const name of SDK_GLOBALS) {
    if (typeof window[name] === "function") return window[name];
  }
  return null;
}

export class H265webWrapper {
  constructor(options = {}) {
    if (!options.video) {
      throw new Error("H265webWrapper requires { video: HTMLVideoElement }");
    }
    if (!options.mountEl) {
      throw new Error("H265webWrapper requires { mountEl: HTMLElement }");
    }
    this.video = options.video;
    this.mountEl = options.mountEl;
    this.baseUrl = options.baseUrl || DEFAULT_BASE_URL;
    this.preferCore = options.core || "webcodec_hevc";
    this.player = null;
    this.events = new Map();
    this._lastPts = 0;
    this._duration = 0;
    this._mediaInfo = null;
  }

  async init() {
    await loadH265webScript(this.baseUrl);
    log.debug("[h265web] script ready");
  }

  async load(url, options = {}) {
    if (!this.player) await this.init();

    const factory = resolveFactory();
    if (!factory) throw new Error("h265web SDK loaded but no factory found");

    if (!this.mountEl.id) {
      this.mountEl.id = `h265web-mount-${Math.floor(Math.random() * 1e9)}`;
    }

    const player = factory();
    this.player = player;

    // Wire the callbacks that `video_player.js` mirrors as native
    // events. h265web emits PTS in seconds (matches `<video>.currentTime`).
    player.on_ready_show_done_callback = () => {
      if (typeof player.get_duration === "function") {
        this._duration = player.get_duration() || this._duration;
      }
      this._emit("ready");
    };
    player.video_probe_callback = (info) => {
      this._mediaInfo = info;
      if (info && typeof info.duration === "number") {
        this._duration = info.duration;
      }
      this._emit("probed", info);
    };
    player.on_play_time = (pts) => {
      this._lastPts = pts;
      this._emit("timeupdate", pts);
    };
    player.on_play_finished = () => this._emit("ended");
    player.on_seek_start_callback = (target) => this._emit("seeking", target);
    player.on_seek_done_callback = (target) => this._emit("seeked", target);
    player.on_load_caching_callback = () => this._emit("waiting");
    player.on_finish_cache_callback = (data) => this._emit("canplay", data);

    player.build({
      player_id: this.mountEl.id,
      base_url: this.baseUrl,
      wasm_js_uri: "h265web_wasm.js",
      wasm_wasm_uri: "h265web_wasm.wasm",
      ext_src_js_uri: "extjs.js",
      ext_wasm_js_uri: "extwasm.js",
      width: "100%",
      height: "100%",
      color: "#000",
      auto_play: options.autoPlay !== false,
      ignore_audio: false,
      readframe_multi_times: -1,
      core: this.preferCore,
    });

    // Swap visible player: hide native <video>, expose h265web mount.
    // Restored on `destroy()`.
    this._previousVideoDisplay = this.video.style.display;
    this.video.style.display = "none";
    this.mountEl.classList.remove("hidden");

    log.debug("[h265web] load_media", { url, core: this.preferCore });
    player.load_media(url);

    if (options.startTime && options.startTime > 0) {
      // h265web ignores seeks before first frame is decoded — defer
      // until the ready callback fires, then jump.
      const onReady = () => {
        try {
          player.seek(options.startTime);
        } catch (err) {
          log.warn("[h265web] seek-on-ready failed:", err);
        }
        this.off("ready", onReady);
      };
      this.on("ready", onReady);
    }
  }

  async play() {
    return this.player?.play?.();
  }

  pause() {
    return this.player?.pause?.();
  }

  async seek(time) {
    return this.player?.seek?.(time);
  }

  getCurrentTime() {
    return this._lastPts || 0;
  }

  getDuration() {
    return this._duration || 0;
  }

  setVolume(volume) {
    const v = Math.max(0, Math.min(1, volume));
    this.player?.set_voice?.(v);
  }

  isPlaying() {
    return !!this.player;
  }

  getMediaInfo() {
    return this._mediaInfo;
  }

  // h265web does not surface track switching the way native <video>
  // does. Catalog GIndex content rarely ships multi-audio, so we leave
  // the track-pick API as a no-op for the spike — UI fallthrough.
  async getAudioTracks() {
    return [];
  }

  async getSubtitleTracks() {
    return [];
  }

  async selectAudioTrack() {
    return null;
  }

  async selectSubtitleTrack() {
    return null;
  }

  async destroy() {
    try {
      this.player?.release?.();
    } catch (err) {
      log.warn("[h265web] release threw:", err);
    } finally {
      this.player = null;
      this.events.clear();
      if (this.video) {
        this.video.style.display = this._previousVideoDisplay || "";
      }
      this.mountEl?.classList.add("hidden");
      // h265web inserts a <canvas> into the mount element. Empty it so
      // a re-mount does not stack canvases.
      while (this.mountEl?.firstChild) this.mountEl.removeChild(this.mountEl.firstChild);
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
        log.warn(`[h265web] handler for ${event} threw`, err);
      }
    }
  }
}

export default H265webWrapper;
