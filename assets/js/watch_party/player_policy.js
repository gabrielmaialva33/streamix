import { playerLogger as log } from "../core/logger.js";

export const PARTY_ROLE = Object.freeze({ HOST: "host", NONE: "none", VIEWER: "viewer" });
export const VIEWER_TRANSPORT_NOTICE = "A reprodução é controlada pelo anfitrião.";
export const VIEWER_PLAY_LABEL = "Reprodução controlada pelo anfitrião";
export const VIEWER_SPEED_LABEL = "Velocidade controlada pelo anfitrião";

const DISABLED_BUTTON_CLASSES = Object.freeze(["cursor-not-allowed", "opacity-60"]);
const DISABLED_PROGRESS_CLASSES = Object.freeze([
  "pointer-events-none",
  "cursor-not-allowed",
  "opacity-70",
]);

/**
 * Watch Party rules applied on the player side.
 *
 * A viewer never drives transport locally: controls are disabled, remote
 * commands from the sync hook are the only allowed source, and a durable sync
 * hold keeps the media paused until the host releases it. Hosts and solo
 * playback are unaffected. Everything the policy touches (root element, video,
 * managed engine, presentation) is injected.
 */
export class WatchPartyPlayerPolicy {
  constructor({
    enabled = false,
    getManagedEngine = () => null,
    getNativeBufferManager = () => null,
    getVideo = () => null,
    logger = log,
    role = PARTY_ROLE.NONE,
    root = null,
    setPlaybackSystemState = () => {},
    showNotice = () => {},
  } = {}) {
    this.enabled = enabled === true;
    this.role = typeof role === "string" && role ? role : PARTY_ROLE.NONE;
    this.root = root;
    this.getVideo = getVideo;
    this.getManagedEngine = getManagedEngine;
    this.getNativeBufferManager = getNativeBufferManager;
    this.setPlaybackSystemState = setPlaybackSystemState;
    this.showNotice = showNotice;
    this.logger = logger;
    this.held = false;
  }

  get isHost() {
    return this.enabled && this.role === PARTY_ROLE.HOST;
  }

  get isViewer() {
    return this.enabled && this.role === PARTY_ROLE.VIEWER;
  }

  canControlTransport({ remote = false } = {}) {
    return remote || !this.enabled || this.role === PARTY_ROLE.HOST;
  }

  rejectViewerTransportControl({ remote = false } = {}) {
    if (this.canControlTransport({ remote })) return false;

    this.showNotice(VIEWER_TRANSPORT_NOTICE);
    return true;
  }

  allowsNativeTouchControls() {
    return !this.isViewer;
  }

  shouldReapplyHoldOnPlay() {
    return this.held && this.isViewer;
  }

  applyControlPolicy() {
    if (!this.isViewer || !this.root?.querySelector) return false;

    const playButton = this.root.querySelector("#play-pause-btn");
    const progress = this.root.querySelector("#progress-container");
    const speedButton = this.root.querySelector("#speed-btn");

    if (playButton) {
      playButton.disabled = true;
      playButton.setAttribute("aria-label", VIEWER_PLAY_LABEL);
      playButton.classList.add(...DISABLED_BUTTON_CLASSES);
    }

    if (progress) {
      progress.setAttribute("aria-disabled", "true");
      progress.classList.add(...DISABLED_PROGRESS_CLASSES);
    }

    if (speedButton) {
      speedButton.disabled = true;
      speedButton.setAttribute("aria-label", VIEWER_SPEED_LABEL);
      speedButton.classList.add(...DISABLED_BUTTON_CLASSES);
    }

    return true;
  }

  setSyncHold(held) {
    const shouldHold = held === true && this.isViewer;
    this.held = shouldHold;
    if (!shouldHold) return true;

    const engine = this.getManagedEngine();

    if (engine) {
      try {
        if (engine.isPlaying?.() !== false) {
          void Promise.resolve(engine.pause?.()).catch(() => {});
        }
      } catch (error) {
        this.logger.debug("[VideoPlayer] Managed sync hold could not pause playback:", error);
      }
    } else {
      const video = this.getVideo();
      if (video && !video.paused) {
        this.getNativeBufferManager()?.markIntentionalPause();
        video.pause();
      }
    }

    this.setPlaybackSystemState("paused");
    return true;
  }

  snapshot() {
    return Object.freeze({
      enabled: this.enabled,
      held: this.held,
      role: this.role,
    });
  }
}

export function createWatchPartyPlayerPolicy(options) {
  return new WatchPartyPlayerPolicy(options);
}
