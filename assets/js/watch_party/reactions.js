export const REACTION_LIFETIME_MS = 2_000;
export const COPY_LABEL_RESTORE_MS = 2_000;
export const COPY_STATUS_ELEMENT_ID = "watch-party-copy-status";
export const REACTIONS_CONTAINER_ID = "wp-reactions-container";

/**
 * Floating emoji reactions and invite-link copy feedback. Everything DOM
 * related lives behind injected references so the hook stays a thin wiring
 * layer and tests can use fakes.
 */
export class ReactionPresenter {
  constructor({
    documentRef = globalThis.document,
    navigatorRef = globalThis.navigator,
    random = Math.random,
    timerApi = globalThis,
  } = {}) {
    this.documentRef = documentRef;
    this.navigatorRef = navigatorRef;
    this.random = random;
    this.timerApi = timerApi;
    this.timers = new Set();
  }

  showFloatingReaction(data) {
    const container = this.documentRef?.getElementById?.(REACTIONS_CONTAINER_ID);
    if (!container || typeof data?.emoji !== "string") return false;

    const element = this.documentRef.createElement("div");
    element.className = "floating-reaction";
    element.textContent = data.emoji;
    element.style.left = `${this.random() * 80}px`;
    container.appendChild(element);

    this.later(() => element.remove(), REACTION_LIFETIME_MS);
    return true;
  }

  async copyInvite(event) {
    const text = event?.detail?.text;
    if (typeof text !== "string" || text.length === 0) return false;

    let copied = false;
    try {
      if (this.navigatorRef?.clipboard?.writeText) {
        await this.navigatorRef.clipboard.writeText(text);
        copied = true;
      }
    } catch {
      copied = false;
    }

    if (!copied) copied = this.legacyCopy(text);
    this.announceCopy(copied, event?.target);
    return copied;
  }

  legacyCopy(text) {
    try {
      const documentRef = this.documentRef;
      const textarea = documentRef.createElement("textarea");
      textarea.value = text;
      textarea.setAttribute("readonly", "");
      textarea.style.position = "fixed";
      textarea.style.opacity = "0";
      documentRef.body.appendChild(textarea);
      textarea.select();
      const copied = documentRef.execCommand?.("copy") === true;
      textarea.remove();
      return copied;
    } catch {
      return false;
    }
  }

  announceCopy(copied, target) {
    const documentRef = this.documentRef;
    let liveRegion = documentRef.getElementById(COPY_STATUS_ELEMENT_ID);
    if (!liveRegion) {
      liveRegion = documentRef.createElement("span");
      liveRegion.id = COPY_STATUS_ELEMENT_ID;
      liveRegion.className = "sr-only";
      liveRegion.setAttribute("aria-live", "polite");
      documentRef.body.appendChild(liveRegion);
    }

    liveRegion.textContent = copied
      ? "Link da Watch Party copiado."
      : "Não foi possível copiar o link.";

    const button = target?.closest?.("button");
    if (button && copied) {
      const originalLabel = button.getAttribute("aria-label");
      button.setAttribute("aria-label", "Link copiado");
      this.later(() => {
        if (originalLabel) button.setAttribute("aria-label", originalLabel);
      }, COPY_LABEL_RESTORE_MS);
    }
  }

  later(callback, delay) {
    const timer = this.timerApi.setTimeout(() => {
      this.timers.delete(timer);
      callback();
    }, delay);
    this.timers.add(timer);
    return timer;
  }

  destroy() {
    for (const timer of this.timers) this.timerApi.clearTimeout(timer);
    this.timers.clear();
  }
}

export function createReactionPresenter(options) {
  return new ReactionPresenter(options);
}
