/**
 * InfiniteScroll Hook - Robust infinite scroll with IntersectionObserver
 *
 * Usage:
 *   <div id="sentinel" phx-hook="InfiniteScroll" data-page={@page} />
 *
 * The hook observes when the sentinel element enters the viewport
 * and triggers "load_more" event. It debounces requests and handles
 * loading state to prevent duplicate calls.
 */

const InfiniteScroll = {
  mounted() {
    this.pending = false;
    this.page = parseInt(this.el.dataset.page || "1", 10);
    this.syncPageUrl = this.el.dataset.syncPageUrl === "true";

    this.observer = new IntersectionObserver(
      (entries) => {
        const entry = entries[0];
        if (entry.isIntersecting) {
          this.loadMore();
        }
      },
      {
        root: null,
        // Trigger before the visible bottom so compact grids keep filling smoothly.
        rootMargin: "800px 0px",
        threshold: 0,
      },
    );

    this.observer.observe(this.el);
    this.scheduleVisibilityCheck();
  },

  updated() {
    // When page changes, reset pending state
    const newPage = parseInt(this.el.dataset.page || "1", 10);
    if (newPage !== this.page) {
      this.page = newPage;
      this.pending = false;
    }

    this.scheduleVisibilityCheck();
  },

  destroyed() {
    this.destroyedHook = true;
    if (this.observer) {
      this.observer.disconnect();
    }
  },

  loadMore() {
    if (this.pending || this.destroyedHook) {
      return;
    }

    this.pending = true;
    this.pushEvent("load_more", {}, (reply) => {
      if (this.syncPageUrl) {
        const page = Number.parseInt(reply?.page || this.el.dataset.page || this.page, 10);
        this.syncPageInUrl(page);
      }

      setTimeout(() => {
        if (!this.destroyedHook) {
          this.pending = false;
          this.scheduleVisibilityCheck();
        }
      }, 100);
    });
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
    requestAnimationFrame(() => {
      if (this.destroyedHook || this.pending) {
        return;
      }

      const rect = this.el.getBoundingClientRect();
      const preloadBottom = window.innerHeight + 800;

      if (rect.top <= preloadBottom && rect.bottom >= 0) {
        this.loadMore();
      }
    });
  },
};

export default InfiniteScroll;
