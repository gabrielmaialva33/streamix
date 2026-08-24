const MEDIA_FATAL_DETAILS = new Set([
  "MEDIA_FORMAT_ERROR",
  "MEDIA_FORMAT_UNSUPPORTED",
  "MEDIA_CODEC_UNSUPPORTED",
]);

const NETWORK_DETAILS = new Set([
  "NETWORK_TIMEOUT",
  "NETWORK_EXCEPTION",
  "NETWORK_UNRECOVERABLE_EARLY_EOF",
]);

const RECREATE_DETAILS = new Set(["MEDIA_MSE_ERROR", "OTHER_ERROR"]);

const normalizeEnum = (value) =>
  String(value || "")
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2")
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
    .replace(/[^a-zA-Z0-9]+/g, "_")
    .replace(/^_|_$/g, "")
    .toUpperCase();

const responseStatus = (errorInfo) => {
  const candidates = [
    errorInfo?.response?.code,
    errorInfo?.response?.status,
    errorInfo?.code,
    errorInfo?.status,
    errorInfo?.statusCode,
  ];

  for (const candidate of candidates) {
    const status = Number(candidate);
    if (Number.isInteger(status) && status >= 100 && status <= 599) return status;
  }

  return null;
};

const fallbackAction = (canTryAVPlayer) =>
  canTryAVPlayer ? "fallback-avplayer" : "fallback-native";

/**
 * Classifies mpegts.js errors using its enum values and structured HTTP status.
 * Human-readable error messages are intentionally ignored.
 */
export function classifyMpegtsError(
  { errorType, errorDetail, errorInfo } = {},
  {
    canTryAVPlayer = false,
    canTryDirect = false,
    maxNetworkAttempts = 3,
    maxRecreateAttempts = 1,
    networkAttempts = 0,
    recreateAttempts = 0,
  } = {},
) {
  const type = normalizeEnum(errorType);
  const detail = normalizeEnum(errorDetail);
  const status = responseStatus(errorInfo);

  if (detail === "RECOVERED_EARLY_EOF") return { action: "ignore", reason: detail };

  if (status === 401 || status === 403) {
    return { action: "refresh-token", reason: `HTTP_${status}`, status };
  }

  // A proxy/CDN response can conceal the real transport or media error. Give
  // the direct URL one clean attempt before demoting the playback engine.
  if (canTryDirect) return { action: "retry-direct", reason: detail || type };

  if (MEDIA_FATAL_DETAILS.has(detail)) {
    return { action: fallbackAction(canTryAVPlayer), reason: detail };
  }

  const isNetworkFailure =
    NETWORK_DETAILS.has(detail) ||
    type === "NETWORK_ERROR" ||
    status === 429 ||
    (status != null && status >= 500);

  if (isNetworkFailure) {
    if (networkAttempts < maxNetworkAttempts) {
      return {
        action: "retry-mpegts",
        counter: "network",
        delayMs: Math.min(200 * 2 ** networkAttempts, 2_000),
        reason: detail || type || `HTTP_${status}`,
      };
    }

    return { action: fallbackAction(canTryAVPlayer), reason: detail || type };
  }

  if (RECREATE_DETAILS.has(detail) || type === "OTHER_ERROR") {
    if (recreateAttempts < maxRecreateAttempts) {
      return {
        action: "retry-mpegts",
        counter: "recreate",
        delayMs: 0,
        reason: detail || type,
      };
    }

    return { action: fallbackAction(canTryAVPlayer), reason: detail || type };
  }

  return { action: fallbackAction(canTryAVPlayer), reason: detail || type || "UNKNOWN" };
}

/**
 * Runs an engine transition only after teardown has completed. Delayed retries
 * are scheduled after teardown and re-check the owning playback session.
 */
export async function executeMpegtsDecision(
  decision,
  {
    cleanup = async () => true,
    fallbackAVPlayer = () => {},
    fallbackNative = () => {},
    isCurrent = () => true,
    refreshToken = () => {},
    retryDirect = () => {},
    retryMpegts = () => {},
    schedule = (callback, delayMs) =>
      new Promise((resolve, reject) => {
        globalThis.setTimeout(() => {
          Promise.resolve().then(callback).then(resolve, reject);
        }, delayMs);
      }),
  } = {},
) {
  if (decision.action === "ignore") return true;
  if (decision.action === "refresh-token") {
    if (isCurrent()) refreshToken();
    return true;
  }

  if (!(await cleanup()) || !isCurrent()) return false;

  const run = () => {
    if (!isCurrent()) return false;

    switch (decision.action) {
      case "retry-direct":
        retryDirect();
        return true;
      case "retry-mpegts":
        retryMpegts();
        return true;
      case "fallback-avplayer":
        fallbackAVPlayer();
        return true;
      case "fallback-native":
        fallbackNative();
        return true;
      default:
        return false;
    }
  };

  if ((decision.delayMs || 0) > 0) {
    return schedule(run, decision.delayMs);
  }

  return run();
}
