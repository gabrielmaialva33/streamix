import { createFocusTrap } from "../core/focus_trap.js";

const BOTTOM_THRESHOLD_PX = 120;
const MOBILE_CHAT_QUERY = "(max-width: 639px)";

const WatchPartyChat = {
  mounted() {
    this.messages = this.el.querySelector("#wp-chat-messages");
    this.input = this.el.querySelector("[data-chat-input]");
    this.trigger = document.querySelector('[aria-controls="watch-party-chat"]');
    this.wasNearBottom = true;
    this.mobileQuery = window.matchMedia?.(MOBILE_CHAT_QUERY) || null;

    this.focusTrap = createFocusTrap(this.el, {
      closeOnClickOutside: false,
      returnFocusTo: this.trigger,
      onEscape: () => this.trigger?.click(),
    });
    this.onViewportModeChange = () => this.syncFocusTrap();
    if (this.mobileQuery?.addEventListener) {
      this.mobileQuery.addEventListener("change", this.onViewportModeChange);
    } else {
      this.mobileQuery?.addListener?.(this.onViewportModeChange);
    }
    this.syncFocusTrap();

    this.focusFrame = requestAnimationFrame(() => {
      this.focusFrame = null;
      this.scrollToBottom();
      this.input?.focus({ preventScroll: true });
    });
  },

  beforeUpdate() {
    this.wasNearBottom = this.isNearBottom();
  },

  updated() {
    this.messages = this.el.querySelector("#wp-chat-messages");
    this.input = this.el.querySelector("[data-chat-input]");
    if (this.wasNearBottom) this.scrollToBottom();
  },

  destroyed() {
    if (this.focusFrame !== null) cancelAnimationFrame(this.focusFrame);
    this.focusFrame = null;
    if (this.mobileQuery?.removeEventListener) {
      this.mobileQuery.removeEventListener("change", this.onViewportModeChange);
    } else {
      this.mobileQuery?.removeListener?.(this.onViewportModeChange);
    }
    this.focusTrap?.deactivate();
    this.focusTrap = null;
    this.mobileQuery = null;
    this.onViewportModeChange = null;
    this.messages = null;
    this.input = null;
    this.trigger = null;
  },

  syncFocusTrap() {
    if (!this.focusTrap) return;

    if (this.mobileQuery?.matches === true) {
      this.focusTrap.activate();
    } else {
      this.focusTrap.deactivate();
    }
  },

  isNearBottom() {
    if (!this.messages) return true;

    return (
      this.messages.scrollHeight - this.messages.scrollTop - this.messages.clientHeight <=
      BOTTOM_THRESHOLD_PX
    );
  },

  scrollToBottom() {
    if (!this.messages) return;
    this.messages.scrollTop = this.messages.scrollHeight;
  },
};

export default WatchPartyChat;
