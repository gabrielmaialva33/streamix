const DEFAULT_HIDE_DELAY_MS = 4_000;

function finitePosition(value) {
  const position = Number(value);
  return Number.isFinite(position) && position >= 0 ? position : 0;
}

function validSourcePayload(payload) {
  return (
    payload &&
    typeof payload.stream_url === "string" &&
    payload.stream_url.length > 0 &&
    Number.isInteger(Number(payload.content_id)) &&
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
} = {}) {
  let pending = false;
  let exhausted = false;
  let destroyed = false;
  let hideTimer = null;
  let terminalError = null;

  const clearHideTimer = () => {
    if (hideTimer !== null) timerApi.clearTimeout(hideTimer);
    hideTimer = null;
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

  return {
    request({ contentId, position = 0, reason = "playback_failed" } = {}) {
      if (!enabled || pending || exhausted || destroyed) return false;

      const sourceId = Number(contentId);
      if (!Number.isInteger(sourceId) || sourceId <= 0) return false;

      pending = true;
      terminalError = { message: String(reason || "Falha na reprodução") };
      renderStatus("Procurando outra fonte disponível…", "loading");

      try {
        pushRequest({
          content_id: sourceId,
          position: finitePosition(position),
          reason: terminalError.message.slice(0, 160),
        });
      } catch {
        pending = false;
        hideStatus();
        return false;
      }

      return true;
    },

    apply(payload) {
      if (destroyed || !validSourcePayload(payload)) return false;

      pending = false;
      exhausted = false;
      terminalError = null;
      renderStatus(payload.message || "Reprodução retomada por outra fonte.", "success", {
        autoHide: true,
      });
      onApply({
        ...payload,
        content_id: Number(payload.content_id),
        resume_time: finitePosition(payload.resume_time),
      });
      return true;
    },

    unavailable(payload = {}) {
      if (destroyed) return false;

      pending = false;
      exhausted = true;
      renderStatus(payload.message || "Nenhuma outra fonte está disponível.", "unavailable", {
        autoHide: true,
      });
      onUnavailable(terminalError, payload);
      terminalError = null;
      return true;
    },

    reset() {
      pending = false;
      exhausted = false;
      terminalError = null;
      hideStatus();
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
      pending = false;
      terminalError = null;
      hideStatus();
      statusElement = null;
    },
  };
}
