import { playerLogger as log } from "../core/logger.js";
import { assertPlaybackEngine, ENGINE_EVENT, ENGINE_ID } from "./engine_contract.js";

function finiteNonNegative(value, fallback = 0) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : fallback;
}

function assertContainer(container) {
  if (!container || typeof container !== "object") {
    throw new TypeError("AVPlayer playback engine requires a container element");
  }

  return container;
}

function assertWrapperClass(AVPlayerWrapper) {
  if (typeof AVPlayerWrapper !== "function") {
    throw new TypeError("AVPlayer playback engine requires the AVPlayerWrapper class");
  }

  return AVPlayerWrapper;
}

/**
 * Contract engine around one `AVPlayerWrapper` (libmedia WASM player).
 *
 * The wrapper still owns script loading, the libmedia player instance and its
 * codec details. This engine owns wrapper construction, translates the
 * wrapper's product callbacks into the shared engine event vocabulary, exposes
 * the contract surface with active-state guards, and provides a bounded
 * snapshot plus idempotent teardown. Product policy (fallbacks, presentation,
 * telemetry) stays with the activation that subscribes to these events.
 */
export class AvPlayerPlaybackEngine {
  constructor({ AVPlayerWrapper, container, logger = log, wrapperOptions = {} } = {}) {
    const Wrapper = assertWrapperClass(AVPlayerWrapper);
    this.container = assertContainer(container);
    this.logger = logger;
    this.listeners = new Map();
    this.destroyed = false;
    this.ready = false;

    this.wrapper = new Wrapper({
      ...wrapperOptions,
      container: this.container,
      onReady: () => {
        this.ready = true;
        this.emit(ENGINE_EVENT.READY);
      },
      onPlay: () => this.emit(ENGINE_EVENT.PLAYING),
      onPause: () => this.emit(ENGINE_EVENT.PAUSED),
      onTimeUpdate: (seconds) => this.emit(ENGINE_EVENT.TIME_UPDATE, finiteNonNegative(seconds)),
      onEnded: () => this.emit(ENGINE_EVENT.ENDED),
      onError: (error) => this.emit(ENGINE_EVENT.ERROR, error),
    });
  }

  get id() {
    return ENGINE_ID.AVPLAYER;
  }

  get client() {
    return this.wrapper;
  }

  init() {
    this.assertActive();
    return this.wrapper.init();
  }

  load(source, options = {}) {
    this.assertActive();
    const url = typeof source === "string" ? source : (source?.url ?? source?.src);
    if (typeof url !== "string" || url.trim() === "") {
      throw new TypeError("AVPlayer playback source requires a non-empty URL");
    }

    return this.wrapper.load(url, options);
  }

  play() {
    this.assertActive();
    return this.wrapper.play();
  }

  pause() {
    if (!this.active) return undefined;
    return this.wrapper.pause();
  }

  stop() {
    if (!this.active) return undefined;
    return this.wrapper.stop?.();
  }

  seek(seconds) {
    if (!this.active) return undefined;
    return this.wrapper.seek(finiteNonNegative(seconds));
  }

  setVolume(volume) {
    if (!this.active) return undefined;
    return this.wrapper.setVolume(volume);
  }

  getCurrentTime() {
    if (!this.active) return 0;
    return finiteNonNegative(this.wrapper.getCurrentTime?.());
  }

  getDuration() {
    if (!this.active) return 0;
    return finiteNonNegative(this.wrapper.getDuration?.());
  }

  isPlaying() {
    if (!this.active) return false;
    return this.wrapper.isPlaying?.() === true;
  }

  getAudioTracks() {
    this.assertActive();
    return this.wrapper.getAudioTracks();
  }

  getSubtitleTracks() {
    this.assertActive();
    return this.wrapper.getSubtitleTracks();
  }

  selectAudioTrack(trackId) {
    this.assertActive();
    return this.wrapper.selectAudioTrack(trackId);
  }

  selectSubtitleTrack(trackId) {
    this.assertActive();
    return this.wrapper.selectSubtitleTrack(trackId);
  }

  loadExternalSubtitle(options) {
    this.assertActive();
    return this.wrapper.loadExternalSubtitle(options);
  }

  setSubtitleDelay(delayMs) {
    this.assertActive();
    return this.wrapper.setSubtitleDelay(delayMs);
  }

  on(event, handler) {
    if (typeof handler !== "function") {
      throw new TypeError("AVPlayer playback engine event handler must be a function");
    }
    if (this.destroyed) return () => {};

    const handlers = this.listeners.get(event) ?? new Set();
    handlers.add(handler);
    this.listeners.set(event, handlers);
    return () => this.off(event, handler);
  }

  off(event, handler) {
    const handlers = this.listeners.get(event);
    if (!handlers) return;

    handlers.delete(handler);
    if (handlers.size === 0) this.listeners.delete(event);
  }

  snapshot() {
    return Object.freeze({
      engine: this.id,
      ready: this.ready,
      destroyed: this.destroyed,
      currentTime: this.getCurrentTime(),
      duration: this.getDuration(),
      paused: !this.isPlaying(),
    });
  }

  destroy() {
    if (this.destroyed) return Promise.resolve(false);

    this.destroyed = true;
    this.ready = false;
    this.listeners.clear();
    const wrapper = this.wrapper;

    let result;
    try {
      result = wrapper.destroy();
    } catch (error) {
      result = Promise.reject(error);
    }

    return Promise.resolve(result).then(() => true);
  }

  get active() {
    return !this.destroyed;
  }

  emit(event, ...args) {
    if (this.destroyed) return;

    for (const handler of [...(this.listeners.get(event) ?? [])]) {
      try {
        handler(...args);
      } catch (error) {
        this.logger.warn(`[AvPlayerPlaybackEngine] handler for ${event} threw`, error);
      }
    }
  }

  assertActive() {
    if (this.destroyed) throw new Error("AVPlayer playback engine has been destroyed");
  }
}

export function createAvPlayerPlaybackEngine(options) {
  return assertPlaybackEngine(new AvPlayerPlaybackEngine(options), { name: "avplayer" });
}
