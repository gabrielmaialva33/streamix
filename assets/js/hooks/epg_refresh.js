// EpgRefresh — periodic "now playing" refresh for visible live cards.
//
// Strategy mirrors iptvnator's throttled EPG queue: we don't push one
// fetch per card. Instead we batch all visible LiveChannel ids and emit
// a single `refresh_epg` event every REFRESH_INTERVAL_MS, so the server
// can do one indexed query (already cached for 60s server-side) and
// stream-update the changed cards in place.
//
// Uses IntersectionObserver to track which cards are currently in the
// viewport, plus a Page Visibility API gate so we don't keep firing
// requests for a backgrounded tab.

const REFRESH_INTERVAL_MS = 60_000;
const VISIBILITY_THRESHOLD = 0.1;
const SELECTOR = "[data-epg-channel-id]";

const EpgRefresh = {
  mounted() {
    this.visibleIds = new Set();
    this.lastRefreshAt = 0;

    this.observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          const id = entry.target.dataset.epgChannelId;
          if (!id) continue;
          if (entry.isIntersecting) {
            this.visibleIds.add(id);
          } else {
            this.visibleIds.delete(id);
          }
        }
      },
      { threshold: VISIBILITY_THRESHOLD },
    );

    this.observeAll();
    this.cardObserver = new MutationObserver(() => this.observeAll());
    this.cardObserver.observe(this.el, { childList: true, subtree: true });

    this.tick = setInterval(() => this.maybeRefresh(), REFRESH_INTERVAL_MS);

    this.onVisibility = () => {
      if (document.visibilityState === "visible") this.maybeRefresh();
    };
    document.addEventListener("visibilitychange", this.onVisibility);
  },

  destroyed() {
    clearInterval(this.tick);
    document.removeEventListener("visibilitychange", this.onVisibility);
    this.observer?.disconnect();
    this.cardObserver?.disconnect();
  },

  observeAll() {
    for (const el of this.el.querySelectorAll(SELECTOR)) {
      if (!el.dataset.epgObserved) {
        this.observer.observe(el);
        el.dataset.epgObserved = "1";
      }
    }
  },

  maybeRefresh() {
    if (document.visibilityState !== "visible") return;
    if (this.visibleIds.size === 0) return;

    const now = Date.now();
    if (now - this.lastRefreshAt < REFRESH_INTERVAL_MS - 1000) return;
    this.lastRefreshAt = now;

    this.pushEvent("refresh_epg", { channel_ids: Array.from(this.visibleIds) });
  },
};

export default EpgRefresh;
