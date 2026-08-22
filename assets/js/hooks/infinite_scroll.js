import {
  automaticLoadLimit,
  automaticPreloadMargin,
  infiniteScrollStateKey,
  parseInfiniteScrollPage,
} from "./infinite_scroll_policy.js";

const PENDING_TIMEOUT_MS = 10_000;
const MAX_ROUTE_STATES = 32;
const routeStates = new Map();

const rememberRouteState = (key, state) => {
  routeStates.delete(key);
  routeStates.set(key, state);

  while (routeStates.size > MAX_ROUTE_STATES) {
    routeStates.delete(routeStates.keys().next().value);
  }
};

/**
 * Controlled infinite scroll.
 *
 * A small number of pages is loaded automatically, then the hook exposes the
 * server-rendered "Carregar mais" button. This prevents an idle sentinel from
 * filling a long-lived mobile tab with hundreds of cards while preserving
 * explicit access to the full catalog.
 */
const InfiniteScroll = {
  mounted() {
    this.destroyedHook = false;
    this.pending = false;
    this.pendingAutomatic = false;
    this.page = parseInfiniteScrollPage(this.el.dataset.page);
    this.syncPageUrl = this.el.dataset.syncPageUrl === "true";
    this.manualButton = this.el.querySelector("[data-infinite-scroll-manual]");
    this.manualLabel = this.el.querySelector("[data-infinite-scroll-label]");
    this.manualIdleLabel = this.manualLabel?.textContent || "Carregar mais";
    this.status = this.el.querySelector("[data-infinite-scroll-status]");
    this.automaticLoadLimit = automaticLoadLimit({
      configured: this.el.dataset.autoLoads,
    });
    this.preloadMargin = automaticPreloadMargin();
    this.syncRouteState();

    this.onManualClick = (event) => {
      // Own the click while the hook is active so manual loads use the same
      // pushEvent callback as automatic loads. That callback is what keeps the
      // restorable `?page=` URL synchronized. The server-side `phx-click`
      // remains a progressive fallback if the hook cannot mount.
      event.preventDefault();
      event.stopPropagation();
      this.loadMore({ automatic: false });
    };
    this.manualButton?.addEventListener("click", this.onManualClick);

    if (typeof IntersectionObserver === "function") {
      this.observer = new IntersectionObserver(
        (entries) => {
          if (entries[0]?.isIntersecting) this.loadMore({ automatic: true });
        },
        {
          root: null,
          rootMargin: `${this.preloadMargin}px 0px`,
          threshold: 0,
        },
      );
    }

    this.renderMode();
    this.scheduleVisibilityCheck();
  },

  updated() {
    const previousPage = this.page;
    const newPage = parseInfiniteScrollPage(this.el.dataset.page, previousPage);
    this.page = newPage;
    this.syncRouteState({ reset: newPage < previousPage });

    if (newPage !== previousPage) {
      this.pending = false;
      this.pendingAutomatic = false;
      this.clearPendingTimeout();
    }

    this.renderMode();
    this.scheduleVisibilityCheck();
  },

  destroyed() {
    this.destroyedHook = true;
    this.manualButton?.removeEventListener("click", this.onManualClick);
    this.observer?.disconnect();
    this.clearPendingTimeout();
    window.cancelAnimationFrame(this.visibilityFrame);
    window.clearTimeout(this.replyTimer);
  },

  syncRouteState({ reset = false } = {}) {
    const nextStateKey = infiniteScrollStateKey({
      elementId: this.el.id,
      locationRef: window.location,
    });
    const storedState = routeStates.get(nextStateKey);

    this.stateKey = nextStateKey;
    if (!storedState || reset || this.page < storedState.page) {
      this.routeState = { page: this.page, automaticLoads: 0 };
    } else {
      this.routeState = storedState;
      this.routeState.page = Math.max(this.routeState.page, this.page);
    }

    rememberRouteState(nextStateKey, this.routeState);
  },

  automaticPaused() {
    return !this.observer || this.routeState.automaticLoads >= this.automaticLoadLimit;
  },

  loadMore({ automatic = false } = {}) {
    if (this.pending || this.destroyedHook) return;

    if (automatic && this.automaticPaused()) {
      this.renderMode();
      return;
    }

    if (automatic) {
      this.routeState.automaticLoads += 1;
    }

    this.pending = true;
    this.pendingAutomatic = automatic;
    this.pendingPage = this.page;
    this.renderMode();
    this.armPendingTimeout();

    this.pushEvent("load_more", {}, (reply) => this.handleLoadReply(reply));
  },

  handleLoadReply(reply) {
    if (this.destroyedHook) return;

    const replyPage = parseInfiniteScrollPage(reply?.page, this.page);
    if (this.syncPageUrl && replyPage >= 1) this.syncPageInUrl(replyPage);

    this.clearPendingTimeout();
    window.clearTimeout(this.replyTimer);
    this.replyTimer = window.setTimeout(() => {
      if (this.destroyedHook) return;
      this.pending = false;
      this.pendingAutomatic = false;
      this.renderMode();
      this.scheduleVisibilityCheck();
    }, 100);
  },

  armPendingTimeout() {
    this.clearPendingTimeout();
    this.pendingTimeout = window.setTimeout(() => {
      if (this.destroyedHook || !this.pending) return;

      if (this.pendingAutomatic && this.page === this.pendingPage) {
        this.routeState.automaticLoads = Math.max(0, this.routeState.automaticLoads - 1);
      }

      this.pending = false;
      this.pendingAutomatic = false;
      this.renderMode();
      this.scheduleVisibilityCheck();
    }, PENDING_TIMEOUT_MS);
  },

  clearPendingTimeout() {
    window.clearTimeout(this.pendingTimeout);
    this.pendingTimeout = null;
  },

  renderMode() {
    const manual = this.automaticPaused();
    this.el.dataset.infiniteScrollMode = this.pending ? "loading" : manual ? "manual" : "automatic";

    if (this.manualButton) {
      this.manualButton.hidden = !manual;
      this.manualButton.disabled = this.pending;
    }
    if (this.manualLabel) {
      this.manualLabel.textContent = this.pending ? "Carregando..." : this.manualIdleLabel;
    }

    if (this.status) {
      this.status.textContent = this.pending
        ? "Carregando mais resultados."
        : manual
          ? "Rolagem automática pausada. Use o botão Carregar mais para continuar."
          : "";
    }

    if (!this.observer) return;
    if (manual) {
      this.observer.unobserve(this.el);
    } else {
      this.observer.observe(this.el);
    }
  },

  syncPageInUrl(page) {
    if (!Number.isInteger(page) || page < 1) return;

    const url = new URL(window.location.href);
    if (page > 1) {
      url.searchParams.set("page", page.toString());
    } else {
      url.searchParams.delete("page");
    }

    window.history.replaceState(
      window.history.state,
      "",
      `${url.pathname}${url.search}${url.hash}`,
    );
  },

  scheduleVisibilityCheck() {
    window.cancelAnimationFrame(this.visibilityFrame);
    this.visibilityFrame = window.requestAnimationFrame(() => {
      if (this.destroyedHook || this.pending || this.automaticPaused()) return;

      const rect = this.el.getBoundingClientRect();
      const preloadBottom = window.innerHeight + this.preloadMargin;

      if (rect.top <= preloadBottom && rect.bottom >= 0) {
        this.loadMore({ automatic: true });
      }
    });
  },
};

export default InfiniteScroll;
