import { playerLogger as log } from "../core/logger.js";
import { isMpegtsSupported } from "../media/player_libs.js";
import { isStreamLoaderCancelledError } from "../media/stream_loader.js";
import { PLAYBACK_STATE } from "./engine_contract.js";
import {
  HLS_RECOVERY_OPERATION,
  HLS_RECOVERY_OUTCOME,
  HLS_RECOVERY_REASON,
} from "./hls_recovery_coordinator.js";
import { assertActivationHost } from "./playback_engine_activation.js";
import { canRetryDirectStream, isDirectStreamUrlAllowed } from "./playback_environment.js";

export const ENGINE_RECOVERY_HOST_METHODS = Object.freeze([
  "canRetry",
  "canTryAVPlayer",
  "cleanup",
  "consumeRetry",
  "getErrorContext",
  "getHlsRecoveryContext",
  "getHlsRecoveryCoordinator",
  "getMpegtsRecoveryCoordinator",
  "getPageProtocol",
  "getSessionId",
  "getStreamUrls",
  "isSessionCurrent",
  "observePlaybackState",
  "playNative",
  "playWithMpegts",
  "pushEvent",
  "recordError",
  "showErrorWithDiagnostics",
  "showPlaybackError",
  "teardownStreamLoaderForTransition",
  "tryAVPlayerFallback",
  "useDirectStream",
]);

export const ENGINE_RECOVERY_TELEMETRY_DEPENDENCIES = Object.freeze([
  "createErrorReport",
  "detectErrorPatterns",
  "formatErrorForLog",
]);

const defaultDependencies = Object.freeze({
  canRetryDirectStream,
  isCancelledError: isStreamLoaderCancelledError,
  isDirectStreamUrlAllowed,
  isMpegtsSupported,
});

function assertDependencies(dependencies) {
  const missing = ENGINE_RECOVERY_TELEMETRY_DEPENDENCIES.filter(
    (name) => typeof dependencies[name] !== "function",
  );
  if (missing.length > 0) {
    throw new TypeError(`EngineRecoveryPolicy dependencies are missing: ${missing.join(", ")}`);
  }
  return dependencies;
}

/**
 * Cross-engine recovery policy for the player hook.
 *
 * Stream errors are reported to telemetry and then routed to the engine
 * coordinators: HLS decisions come from the HlsRecoveryCoordinator (the
 * transport-local retries live there) and MPEG-TS decisions from the
 * MpegtsRecoveryCoordinator. This policy owns what happens when those
 * coordinators give up: the product fallbacks across engines (HLS →
 * mpegts.js → native, proxy → direct URL, mpegts.js → AVPlayer), token
 * refresh requests, and the terminal error presentation. The telemetry
 * helpers (error report, log formatting, pattern detection) are injected by
 * the host so this module stays free of browser-only imports.
 */
export class EngineRecoveryPolicy {
  constructor({ dependencies = {}, host, logger = log } = {}) {
    this.host = assertActivationHost(host, ENGINE_RECOVERY_HOST_METHODS, "EngineRecoveryPolicy");
    this.deps = assertDependencies({ ...defaultDependencies, ...dependencies });
    this.logger = logger;
  }

  reportHlsRecoveryFailure(error) {
    if (this.deps.isCancelledError(error)) return;
    this.logger.warn("HLS recovery failed:", error);
    this.host.showErrorWithDiagnostics(
      "Nao foi possivel recuperar o stream",
      { message: error?.message || String(error), type: "network" },
      true,
    );
  }

  logHlsRecoveryDecision(decision) {
    switch (decision.reason) {
      case HLS_RECOVERY_REASON.MANIFEST_SOFT_RELOAD:
        this.logger.warn(`Soft recovering HLS (attempt ${decision.nextAttempts})...`);
        break;
      case HLS_RECOVERY_REASON.NETWORK_RESTART:
        this.logger.warn(
          `Network error, restarting HLS load (attempt ${decision.nextAttempts})...`,
        );
        break;
      case HLS_RECOVERY_REASON.NETWORK_SOFT_RELOAD:
        this.logger.warn("Network recovery exhausted, soft reloading HLS...");
        break;
      case HLS_RECOVERY_REASON.MEDIA_RECOVERY:
        this.logger.warn(`Media error, recovering HLS (attempt ${decision.nextAttempts})...`);
        break;
      case HLS_RECOVERY_REASON.MEDIA_SOFT_RELOAD:
        this.logger.warn("Media recovery exhausted, soft reloading HLS...");
        break;
      default:
        this.logger.warn("[VideoPlayer] HLS recovery started:", {
          operation: decision.operation,
          reason: decision.reason,
        });
    }
  }

  handleHlsFallback(decision) {
    if (decision.reason === HLS_RECOVERY_REASON.MANIFEST_UNAVAILABLE) {
      if (this.host.canRetry() && this.deps.isMpegtsSupported()) {
        this.host.consumeRetry();
        this.logger.warn("HLS failed, trying mpegts.js...");
        this.host.observePlaybackState(PLAYBACK_STATE.RECOVERING, "hls_to_mpegts_fallback");
        this.host.cleanup({ preservePlaybackState: true });
        this.host.playWithMpegts();
      } else {
        this.host.showErrorWithDiagnostics(
          "Não foi possível carregar — servidor indisponível",
          { message: "Manifest load failed", type: "network" },
          true,
        );
      }
      return;
    }

    if (this.host.canRetry()) {
      this.host.consumeRetry();
      this.host.observePlaybackState(PLAYBACK_STATE.RECOVERING, "hls_engine_fallback");
      this.host.cleanup({ preservePlaybackState: true });
      if (this.deps.isMpegtsSupported()) {
        this.host.playWithMpegts();
      } else {
        this.host.playNative();
      }
    } else {
      this.host.showErrorWithDiagnostics(
        "Erro de reprodução — formato não suportado",
        { message: "Media format error", type: "codec" },
        true,
      );
    }
  }

  handleHlsStreamError(data) {
    const recovery = this.host
      .getHlsRecoveryCoordinator()
      .handle(data, this.host.getHlsRecoveryContext());
    const { decision } = recovery;

    switch (decision.outcome) {
      case HLS_RECOVERY_OUTCOME.IGNORED:
        this.logger.debug("HLS non-fatal error:", decision.event.details);
        break;
      case HLS_RECOVERY_OUTCOME.REFRESH_TOKEN:
        this.logger.warn("Auth error detected, requesting token refresh");
        this.host.pushEvent("request_token_refresh", {});
        break;
      case HLS_RECOVERY_OUTCOME.RECOVERY_RUNNING:
      case HLS_RECOVERY_OUTCOME.RECOVERY_SCHEDULED:
        this.logHlsRecoveryDecision(decision);
        break;
      case HLS_RECOVERY_OUTCOME.FALLBACK_REQUIRED:
        this.handleHlsFallback(decision);
        break;
      default:
        this.logger.warn("[VideoPlayer] Unknown HLS recovery outcome:", decision);
        this.handleHlsFallback({
          ...decision,
          operation: HLS_RECOVERY_OPERATION.SOFT_RELOAD,
          reason: HLS_RECOVERY_REASON.UNHANDLED_FATAL,
        });
    }

    return recovery;
  }

  handleStreamError(type, data) {
    this.host.recordError();

    // Create enriched error report for telemetry
    const context = this.host.getErrorContext();
    const errorReport = this.deps.createErrorReport(
      { message: data.details || data.errorDetail || "Stream error", type },
      {
        type,
        contentId: context.contentId,
        contentType: context.contentType,
        streamUrl: context.currentUrl,
        player: type,
        videoElement: context.video,
        playerState: {
          usingAVPlayer: context.usingAVPlayer,
          streamingMode: context.streamingMode,
          streamType: context.streamType,
          sourceType: context.sourceType,
        },
        retryCount: context.retryCount,
        fallbackAttempt: context.fallbackAttempts,
        fatal: data.fatal,
      },
    );

    this.logger.debug(this.deps.formatErrorForLog(errorReport));

    // Send enriched error to backend
    this.host.pushEvent("player_error", {
      ...errorReport,
      patterns: this.deps.detectErrorPatterns(),
    });

    if (type === "hls") {
      this.handleHlsStreamError(data);
    } else if (type === "mpegts") {
      void this.recoverFromMpegtsError(data);
    }
  }

  recoverFromMpegtsError(data) {
    const sessionId = this.host.getSessionId();
    let transitionSessionId = sessionId;

    return this.host.getMpegtsRecoveryCoordinator().handle(data, {
      sessionId,
      canTryAVPlayer: this.host.canTryAVPlayer(),
      canTryDirect: this.deps.canRetryDirectStream({
        ...this.host.getStreamUrls(),
        pageProtocol: this.host.getPageProtocol(),
      }),
      cleanup: async () => {
        const nextSessionId = await this.host.teardownStreamLoaderForTransition(sessionId);
        if (nextSessionId == null) return false;
        transitionSessionId = nextSessionId;
        return true;
      },
      isCurrent: () => this.host.isSessionCurrent(transitionSessionId),
      refreshToken: () => {
        this.logger.warn("mpegts.js authentication failed; requesting a fresh token");
        this.host.pushEvent("request_token_refresh", {});
      },
      retryDirect: () => {
        const { streamUrl } = this.host.getStreamUrls();
        if (!this.deps.isDirectStreamUrlAllowed(streamUrl, this.host.getPageProtocol())) {
          this.logger.warn("mpegts.js direct retry blocked by mixed-content policy");
          void this.host.playWithMpegts();
          return;
        }

        this.logger.warn("mpegts.js proxy path failed; retrying the direct URL");
        this.host.useDirectStream();
        void this.host.playWithMpegts();
      },
      retryMpegts: (decision) => {
        this.logger.warn(`Recreating mpegts.js after ${decision?.reason ?? "transport error"}`);
        void this.host.playWithMpegts();
      },
      fallbackAVPlayer: () => {
        this.logger.warn("mpegts.js recovery exhausted; trying AVPlayer");
        void this.host.tryAVPlayerFallback();
      },
      fallbackNative: () => this.host.playNative(),
      onFailure: (error) => {
        this.logger.error("mpegts.js recovery failed:", error);
        if (this.host.isSessionCurrent(transitionSessionId)) {
          this.host.showPlaybackError("Erro ao recuperar o stream ao vivo");
        }
      },
    });
  }
}

export function createEngineRecoveryPolicy(options) {
  return new EngineRecoveryPolicy(options);
}
