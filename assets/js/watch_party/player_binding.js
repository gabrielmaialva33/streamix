import { PLAYBACK_BRIDGE_EVENT } from "../player/playback_bridge.js";

export const PLAYER_CONTAINER_ID = "video-player-container";
export const BUFFERING_EVENT = "streamix:buffering";
export const PLAYER_POLL_FAST_ATTEMPTS = 50;
export const PLAYER_POLL_FAST_MS = 200;
export const PLAYER_POLL_SLOW_MS = 2_000;

const NATIVE_HLS_MIME_TYPES = Object.freeze([
  "application/vnd.apple.mpegurl",
  "application/x-mpegURL",
]);
const HOST_EVENT_TO_PUSH = Object.freeze({ play: "wp_play", pause: "wp_pause", seeked: "wp_seek" });

function requiredFunction(value, name) {
  if (typeof value !== "function") {
    throw new TypeError(`WatchPartyPlayerBinding requires ${name}()`);
  }
  return value;
}

/**
 * Binds the sync loop to the player bridge published on the player container.
 *
 * Owns discovery/polling of the player element, the media buffering signals,
 * host transport forwarding and deterministic unbinding. The hook that owns
 * this binding is marked on the player container so a LiveView re-render can
 * detect a stale binding and rebind.
 */
export class WatchPartyPlayerBinding {
  constructor({
    documentRef = globalThis.document,
    getSyncHold = () => false,
    isDestroyed = () => false,
    isHost = false,
    onBound = () => {},
    onBuffering,
    onHostPlaybackEvent = () => {},
    owner,
    shouldForwardHostEvent = () => true,
    timerApi = globalThis,
  } = {}) {
    this.documentRef = documentRef;
    this.timerApi = timerApi;
    this.isHost = isHost === true;
    this.owner = owner ?? this;
    this.getSyncHold = requiredFunction(getSyncHold, "getSyncHold");
    this.isDestroyed = requiredFunction(isDestroyed, "isDestroyed");
    this.onBound = requiredFunction(onBound, "onBound");
    this.onBuffering = requiredFunction(onBuffering, "onBuffering");
    this.onHostPlaybackEvent = requiredFunction(onHostPlaybackEvent, "onHostPlaybackEvent");
    this.shouldForwardHostEvent = requiredFunction(
      shouldForwardHostEvent,
      "shouldForwardHostEvent",
    );

    this.playerEl = null;
    this.videoEl = null;
    this.playback = null;
    this.nativeHlsPlayback = false;
    this.waitTimer = null;
    this.handlers = null;
  }

  get bound() {
    return this.playback != null;
  }

  waitForPlayer(attempts = 0) {
    if (this.isDestroyed()) return false;
    if (this.ensure()) return true;

    const delay = attempts < PLAYER_POLL_FAST_ATTEMPTS ? PLAYER_POLL_FAST_MS : PLAYER_POLL_SLOW_MS;
    this.clearWait();
    this.waitTimer = this.timerApi.setTimeout(() => {
      this.waitTimer = null;
      this.waitForPlayer(attempts + 1);
    }, delay);
    return false;
  }

  ensure() {
    if (this.isDestroyed()) return false;

    const playerEl = this.documentRef?.getElementById?.(PLAYER_CONTAINER_ID) ?? null;
    const videoEl = playerEl?.querySelector?.("video") || null;
    if (!playerEl?.streamixPlayback || !videoEl) return false;

    if (
      this.playerEl !== playerEl ||
      this.playback !== playerEl.streamixPlayback ||
      playerEl.__watchPartySyncHook !== this.owner
    ) {
      this.bind(playerEl, videoEl);
    }

    return true;
  }

  bind(playerEl, videoEl) {
    if (
      this.playerEl === playerEl &&
      this.playback === playerEl.streamixPlayback &&
      playerEl.__watchPartySyncHook === this.owner
    ) {
      return false;
    }

    this.unbind();
    this.clearWait();
    this.playerEl = playerEl;
    this.videoEl = videoEl;
    this.playback = playerEl.streamixPlayback;
    this.playback.setSyncHold?.(this.getSyncHold());
    playerEl.__watchPartySyncHook = this.owner;
    this.nativeHlsPlayback = NATIVE_HLS_MIME_TYPES.some((mimeType) =>
      Boolean(videoEl.canPlayType?.(mimeType)),
    );

    const handlers = {
      buffering: (event) => {
        if (typeof event.detail?.buffering === "boolean") {
          this.onBuffering(event.detail.buffering);
        }
      },
      waiting: () => this.onBuffering(true),
      canplay: () => this.onBuffering(false),
      playing: () => this.onBuffering(false),
      playback: null,
    };
    playerEl.addEventListener(BUFFERING_EVENT, handlers.buffering);
    videoEl.addEventListener("waiting", handlers.waiting);
    videoEl.addEventListener("canplay", handlers.canplay);
    videoEl.addEventListener("playing", handlers.playing);

    if (this.isHost) {
      handlers.playback = (event) => {
        if (!this.shouldForwardHostEvent()) return;
        const pushName = HOST_EVENT_TO_PUSH[event.detail?.type];
        if (pushName) this.onHostPlaybackEvent(pushName, this.position());
      };
      playerEl.addEventListener(PLAYBACK_BRIDGE_EVENT, handlers.playback);
    }

    this.handlers = handlers;
    this.onBound();
    return true;
  }

  unbind() {
    this.playback?.setSyncHold?.(false);

    if (this.playerEl?.__watchPartySyncHook === this.owner) {
      delete this.playerEl.__watchPartySyncHook;
    }

    const { playerEl, videoEl, handlers } = this;
    if (playerEl && handlers) {
      playerEl.removeEventListener(BUFFERING_EVENT, handlers.buffering);
      if (handlers.playback) playerEl.removeEventListener(PLAYBACK_BRIDGE_EVENT, handlers.playback);
    }
    if (videoEl && handlers) {
      videoEl.removeEventListener("waiting", handlers.waiting);
      videoEl.removeEventListener("canplay", handlers.canplay);
      videoEl.removeEventListener("playing", handlers.playing);
    }

    const wasBound = this.playback != null;
    this.handlers = null;
    this.playerEl = null;
    this.videoEl = null;
    this.playback = null;
    return wasBound;
  }

  position() {
    const position = Number(this.playback?.getCurrentTime?.());
    return Number.isFinite(position) && position >= 0 ? position : 0;
  }

  isPaused() {
    return this.playback?.isPaused?.() ?? true;
  }

  clearWait() {
    if (this.waitTimer) this.timerApi.clearTimeout(this.waitTimer);
    this.waitTimer = null;
  }

  destroy() {
    this.clearWait();
    this.unbind();
  }
}

export function createWatchPartyPlayerBinding(options) {
  return new WatchPartyPlayerBinding(options);
}
