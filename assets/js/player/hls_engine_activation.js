import { playerLogger as log } from "../core/logger.js";
import { isHlsJsSupported } from "../media/player_libs.js";
import { isStreamLoaderCancelledError } from "../media/stream_loader.js";
import { ENGINE_ID, ENGINE_SELECTION } from "./engine_contract.js";
import {
  assertActivationHost,
  PLAYBACK_ENGINE_ACTIVATION_HOST_METHODS,
} from "./playback_engine_activation.js";
import { guardPlaybackLoad } from "./playback_load_guard.js";

export const HLS_UNSUPPORTED_MESSAGE = "HLS nao suportado neste navegador";

const NATIVE_HLS_MIME_TYPE = "application/vnd.apple.mpegurl";

export const HLS_ENGINE_ACTIVATION_HOST_METHODS = Object.freeze([
  ...PLAYBACK_ENGINE_ACTIVATION_HOST_METHODS,
  "ensureStreamLoader",
  "getNativeHlsSupport",
  "getStreamLoader",
  "getVideo",
  "recordPlaybackError",
  "registerMediaElementEngine",
  "reportLifecycle",
  "setNativePlaybackEventsSuppressed",
  "showPlaybackError",
  "syncPiPAvailability",
  "teardownStreamLoaderForTransition",
]);

const defaultDependencies = {
  guardPlaybackLoad,
  isHlsJsSupported,
  isStreamLoaderCancelledError,
};

/**
 * Activates hls.js playback through the transport owned by StreamLoader.
 *
 * StreamLoader still creates and destroys the HLS engine; this activation only
 * drives the guarded load, borrows the resulting engine into the shared media
 * element registry and applies the native/unsupported fallbacks.
 */
export class HlsEngineActivation {
  constructor({ dependencies = {}, host, logger = log } = {}) {
    this.host = assertActivationHost(
      host,
      HLS_ENGINE_ACTIVATION_HOST_METHODS,
      "HlsEngineActivation",
    );
    this.deps = { ...defaultDependencies, ...dependencies };
    this.logger = logger;
  }

  get id() {
    return ENGINE_ID.HLS;
  }

  get selection() {
    return ENGINE_SELECTION.HLS_JS;
  }

  /**
   * Registers the loader-owned HLS engine for the current session. StreamLoader
   * callbacks call this lazily (manifest parsed, track updates) because the
   * engine only exists once hls.js has been loaded.
   */
  adoptLoaderEngine(sessionId = this.host.getSessionId(), loader = this.host.getStreamLoader()) {
    if (
      !this.host.isSessionCurrent(sessionId) ||
      !loader ||
      this.host.getStreamLoader() !== loader
    ) {
      return null;
    }

    const hlsEngine = loader.getHlsEngine?.();
    if (!hlsEngine || hlsEngine.destroyed) return null;

    return this.host.registerMediaElementEngine(ENGINE_ID.HLS, hlsEngine);
  }

  async activate(request) {
    const { activate, sessionId, url } = request;

    this.host.setNativePlaybackEventsSuppressed(false);
    this.host.syncPiPAvailability();
    this.logger.info("Playing with HLS.js, url:", url);
    this.host.reportLifecycle("player_engine_selected", { engine: ENGINE_ID.HLS });

    if (!this.deps.isHlsJsSupported()) {
      if (this.host.getVideo()?.canPlayType(NATIVE_HLS_MIME_TYPE)) {
        return activate(ENGINE_SELECTION.NATIVE, { sessionId });
      }

      this.host.showPlaybackError(HLS_UNSUPPORTED_MESSAGE);
      return false;
    }

    const loader = this.host.ensureStreamLoader();
    const result = await this.deps.guardPlaybackLoad({
      load: () => loader.loadHls(url),
      isCancelled: this.deps.isStreamLoaderCancelledError,
      isCurrent: () =>
        this.host.isSessionCurrent(sessionId) && this.host.getStreamLoader() === loader,
      destroy: () => loader.destroy(),
    });

    if (result.status === "cancelled" || result.status === "stale") return false;

    if (result.status === "loaded") {
      if (!this.adoptLoaderEngine(sessionId, loader)) {
        throw new Error("HLS engine was not registered by StreamLoader");
      }
      return true;
    }

    this.logger.error("HLS.js initialization failed:", result.error);
    this.host.recordPlaybackError();
    const transitionSessionId = await this.host.teardownStreamLoaderForTransition(sessionId);
    if (transitionSessionId == null) return false;

    if (this.host.getNativeHlsSupport()) {
      return activate(ENGINE_SELECTION.NATIVE, { sessionId: transitionSessionId });
    }

    this.host.showPlaybackError(HLS_UNSUPPORTED_MESSAGE);
    return false;
  }
}

export function createHlsEngineActivation(options) {
  return new HlsEngineActivation(options);
}
