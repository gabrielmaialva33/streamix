import { playerLogger as log } from "../core/logger.js";
import { isStreamLoaderCancelledError } from "../media/stream_loader.js";
import { ENGINE_ID, ENGINE_SELECTION } from "./engine_contract.js";
import {
  assertActivationHost,
  PLAYBACK_ENGINE_ACTIVATION_HOST_METHODS,
} from "./playback_engine_activation.js";
import { guardPlaybackLoad } from "./playback_load_guard.js";

export const FLV_UNSUPPORTED_MESSAGE = "Reproducao FLV nao suportada neste navegador";

export const MPEGTS_ENGINE_ACTIVATION_HOST_METHODS = Object.freeze([
  ...PLAYBACK_ENGINE_ACTIVATION_HOST_METHODS,
  "clearStreamLoader",
  "ensureStreamLoader",
  "getMpegtsPlayer",
  "getPresentation",
  "getStreamLoader",
  "getTransitionController",
  "getVideo",
  "markMpegtsRecovered",
  "playNativeAfterResume",
  "recordPlaybackError",
  "recoverFromMpegtsError",
  "registerMediaElementEngine",
  "releaseEngine",
  "reportDebug",
  "reportLifecycle",
  "setMpegtsPlayer",
  "setNativePlaybackEventsSuppressed",
  "showPlaybackError",
  "syncPiPAvailability",
  "teardownStreamLoaderForTransition",
]);

const defaultDependencies = {
  guardPlaybackLoad,
  isStreamLoaderCancelledError,
};

function mpegtsType(selection) {
  return selection === ENGINE_SELECTION.MPEGTS_FLV ? "flv" : "mpegts";
}

/**
 * Activates mpegts.js playback (MPEG-TS and FLV) as one transition owned by
 * the shared PlaybackEngineTransitionController.
 *
 * StreamLoader remains the transport owner: it creates and destroys the
 * mpegts.js engine. This activation sequences the guarded load, borrows the
 * engine into the media element registry, and routes failures back to the
 * host's recovery policy.
 */
export class MpegtsEngineActivation {
  constructor({ dependencies = {}, host, logger = log } = {}) {
    this.host = assertActivationHost(
      host,
      MPEGTS_ENGINE_ACTIVATION_HOST_METHODS,
      "MpegtsEngineActivation",
    );
    this.deps = { ...defaultDependencies, ...dependencies };
    this.logger = logger;
  }

  get id() {
    return ENGINE_ID.MPEGTS;
  }

  get selection() {
    return ENGINE_SELECTION.MPEGTS;
  }

  activate(request) {
    const type = mpegtsType(request.selection);
    const controller = this.host.getTransitionController();
    if (!controller) return Promise.resolve(false);

    return controller.transition({
      key: `startup-mpegts-${type}`,
      sessionId: request.sessionId,
      capture: () => ({ type }),
      createEngine: () => this.host.ensureStreamLoader(),
      loadEngine: (context) => this.load(type, context.sessionId),
      registerEngine: ({ engine: loader }) => {
        const mpegtsEngine = loader.getMpegtsEngine();
        if (!mpegtsEngine) {
          throw new Error("MPEG-TS transition completed without an engine");
        }
        return mpegtsEngine;
      },
      activateEngine: ({ engine: loader }) => Boolean(loader.getMpegtsEngine()),
      complete: ({ engine: loader }) => loader.getMpegtsEngine(),
      rollbackEngine: ({ engine: loader }) => {
        this.host.releaseEngine(ENGINE_ID.MPEGTS);
        if (this.host.getMpegtsPlayer() === loader.getMpegtsPlayer()) {
          this.host.setMpegtsPlayer(null);
        }
      },
      destroyEngine: async (loader) => {
        await loader.destroy();
        this.host.clearStreamLoader(loader);
      },
      onFailure: async (error, context) => {
        if (!this.host.isSessionCurrent(context.sessionId)) return false;

        if (context.capture?.type === "flv") {
          const transitionSessionId = await this.host.teardownStreamLoaderForTransition(
            context.sessionId,
          );
          if (transitionSessionId != null) {
            this.host.showPlaybackError(FLV_UNSUPPORTED_MESSAGE);
          }
          return false;
        }

        return this.host.recoverFromMpegtsError({
          errorType: "OtherError",
          errorDetail: "OtherError",
          errorInfo: { cause: error },
        });
      },
    });
  }

  async load(type, sessionId = this.host.getSessionId()) {
    const url = this.host.getCurrentUrl();

    this.host.setNativePlaybackEventsSuppressed(false);
    this.host.syncPiPAvailability();
    this.logger.info("Playing with mpegts.js, type:", type, "url:", url);
    this.host.reportDebug("play_with_mpegts", { requested_type: type });
    this.host.reportLifecycle("player_engine_selected", {
      engine: ENGINE_ID.MPEGTS,
      requested_type: type,
      session_id: sessionId,
    });

    const loader = this.host.ensureStreamLoader();
    const video = this.host.getVideo();
    const onPlaying = () => {
      if (!this.host.isSessionCurrent(sessionId)) return;
      this.host.markMpegtsRecovered();
      const presentation = this.host.getPresentation();
      presentation?.hideLoading();
      presentation?.hideError();
    };
    video?.addEventListener("playing", onPlaying, { once: true });

    const result = await this.deps.guardPlaybackLoad({
      load: () => loader.loadMpegts(url, type),
      isCancelled: this.deps.isStreamLoaderCancelledError,
      isCurrent: () =>
        this.host.isSessionCurrent(sessionId) && this.host.getStreamLoader() === loader,
      destroy: () => undefined,
    });

    if (result.status === "cancelled" || result.status === "stale") {
      video?.removeEventListener("playing", onPlaying);
      throw result.error || new Error(`MPEG-TS load became ${result.status}`);
    }

    if (result.status === "loaded") {
      const mpegtsEngine = loader.getMpegtsEngine();
      this.host.setMpegtsPlayer(loader.getMpegtsPlayer());
      this.host.registerMediaElementEngine(ENGINE_ID.MPEGTS, mpegtsEngine);

      void Promise.resolve(this.host.playNativeAfterResume(sessionId)).catch((error) => {
        if (this.host.isSessionCurrent(sessionId)) {
          this.logger.debug("mpegts.js play request failed:", error);
        }
      });

      return;
    }

    video?.removeEventListener("playing", onPlaying);
    this.logger.error("mpegts.js initialization error:", result.error);
    this.host.recordPlaybackError();
    throw result.error;
  }
}

export function createMpegtsEngineActivation(options) {
  return new MpegtsEngineActivation(options);
}
