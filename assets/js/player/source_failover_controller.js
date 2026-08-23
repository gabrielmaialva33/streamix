const DEFAULT_HIDE_DELAY_MS = 4_000;
const DEFAULT_REQUEST_TIMEOUT_MS = 15_000;
const MAX_REQUEST_ID_LENGTH = 128;

function finitePosition(value) {
  const position = Number(value);
  return Number.isFinite(position) && position >= 0 ? position : 0;
}

function normalizeRequestId(value) {
  if (typeof value !== "string") return null;

  const requestId = value.trim();
  return requestId.length > 0 && requestId.length <= MAX_REQUEST_ID_LENGTH ? requestId : null;
}

function defaultRequestIdFactory(sequence) {
  const uuid = globalThis.crypto?.randomUUID?.();
  if (uuid) return uuid;

  return `failover-${Date.now().toString(36)}-${sequence.toString(36)}`;
}

function validSourcePayload(payload) {
  const streamUrl = typeof payload?.stream_url === "string" ? payload.stream_url.trim() : "";

  return (
    streamUrl.length > 0 &&
    Number.isInteger(Number(payload?.content_id)) &&
    Number(payload.content_id) > 0
  );
}

export function createSourceFailoverController({
  enabled = false,
  onApply = () => {},
  onUnavailable = () => {},
  pushRequest = () => {},
  statusElement = null,
  timerApi = globalThis,
  hideDelayMs = DEFAULT_HIDE_DELAY_MS,
  requestTimeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
  requestIdFactory = defaultRequestIdFactory,
} = {}) {
  let pending = false;
  let exhausted = false;
  let destroyed = false;
  let hideTimer = null;
  let requestTimer = null;
  let terminalError = null;
  let requestSequence = 0;
  let activeRequestId = null;

  const clearHideTimer = () => {
    if (hideTimer !== null) timerApi.clearTimeout(hideTimer);
    hideTimer = null;
  };

  const clearRequestTimer = () => {
    if (requestTimer !== null) timerApi.clearTimeout(requestTimer);
    requestTimer = null;
  };

  const hideStatus = () => {
    clearHideTimer();
    statusElement?.classList.add("hidden");
  };

  const renderStatus = (message, state = "loading", { autoHide = false } = {}) => {
    if (!statusElement || destroyed) return;

    clearHideTimer();
    statusElement.dataset.failoverState = state;
    const text = statusElement.querySelector("[data-source-failover-text]");
    if (text) text.textContent = message;
    statusElement.classList.remove("hidden");

    if (autoHide) {
      hideTimer = timerApi.setTimeout(() => {
        hideTimer = null;
        statusElement.classList.add("hidden");
      }, hideDelayMs);
    }
  };

  const nextRequestId = () => {
    requestSequence += 1;
    return normalizeRequestId(requestIdFactory(requestSequence)) || `failover-${requestSequence}`;
  };

  const matchesActiveRequest = (payload) => {
    const responseRequestId = normalizeRequestId(payload?.request_id);
    return activeRequestId !== null && responseRequestId === activeRequestId;
  };

  const scheduleRequestTimeout = () => {
    clearRequestTimer();
    if (!Number.isFinite(requestTimeoutMs) || requestTimeoutMs <= 0) return;

    const requestId = activeRequestId;

    requestTimer = timerApi.setTimeout(() => {
      requestTimer = null;
      if (destroyed || !pending || activeRequestId !== requestId) return;

      pending = false;
      exhausted = true;
      activeRequestId = null;
      const payload = {
        request_id: requestId,
        reason: "timeout",
        message: "A busca por outra fonte demorou demais.",
      };
      renderStatus(payload.message, "unavailable", { autoHide: true });
      onUnavailable(terminalError, payload);
      terminalError = null;
    }, requestTimeoutMs);
  };

  return {
    request({ contentId, position = 0, reason = "playback_failed" } = {}) {
      if (!enabled || pending || exhausted || destroyed) return false;

      const sourceId = Number(contentId);
      if (!Number.isInteger(sourceId) || sourceId <= 0) return false;

      const requestId = nextRequestId();
      pending = true;
      activeRequestId = requestId;
      terminalError = { message: String(reason || "Falha na reprodução") };
      renderStatus("Procurando outra fonte disponível…", "loading");
      scheduleRequestTimeout();

      try {
        pushRequest({
          content_id: sourceId,
          position: finitePosition(position),
          reason: terminalError.message.slice(0, 160),
          request_id: requestId,
        });
      } catch {
        clearRequestTimer();
        pending = false;
        activeRequestId = null;
        terminalError = null;
        hideStatus();
        return false;
      }

      return true;
    },

    apply(payload) {
      if (destroyed || !validSourcePayload(payload) || !matchesActiveRequest(payload)) return false;

      const requestId = activeRequestId;
      const normalizedPayload = {
        ...payload,
        content_id: Number(payload.content_id),
        request_id: requestId,
        resume_time: finitePosition(payload.resume_time),
        stream_url: payload.stream_url.trim(),
      };

      clearRequestTimer();
      pending = false;
      exhausted = false;
      activeRequestId = null;
      terminalError = null;
      renderStatus(payload.message || "Reprodução retomada por outra fonte.", "success", {
        autoHide: true,
      });
      onApply(normalizedPayload);
      return true;
    },

    unavailable(payload = {}) {
      if (destroyed || !matchesActiveRequest(payload) || (!pending && terminalError === null)) {
        return false;
      }

      const requestId = activeRequestId;
      const normalizedPayload = { ...payload, request_id: requestId };

      clearRequestTimer();
      pending = false;
      exhausted = true;
      activeRequestId = null;
      renderStatus(payload.message || "Nenhuma outra fonte está disponível.", "unavailable", {
        autoHide: true,
      });
      onUnavailable(terminalError, normalizedPayload);
      terminalError = null;
      return true;
    },

    reset() {
      clearRequestTimer();
      pending = false;
      exhausted = false;
      activeRequestId = null;
      terminalError = null;
      hideStatus();
    },

    get activeRequestId() {
      return activeRequestId;
    },

    get pending() {
      return pending;
    },

    get exhausted() {
      return exhausted;
    },

    destroy() {
      if (destroyed) return;
      destroyed = true;
      clearRequestTimer();
      pending = false;
      activeRequestId = null;
      terminalError = null;
      hideStatus();
      statusElement = null;
    },
  };
}
