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

    this.observer = new IntersectionObserver(
      (entries) => {
        const entry = entries[0];
        if (entry.isIntersecting && !this.pending) {
          this.pending = true;
          this.pushEvent("load_more", {}, () => {
            // Callback after server acknowledges - small delay before allowing next
            setTimeout(() => {
              this.pending = false;
            }, 100);
          });
        }
      },
      {
        root: null,
        // Trigger 400px before sentinel is visible for smoother loading
        rootMargin: "400px",
        threshold: 0,
      },
    );

    this.observer.observe(this.el);
  },

  updated() {
    // When page changes, reset pending state
    const newPage = parseInt(this.el.dataset.page || "1", 10);
    if (newPage !== this.page) {
      this.page = newPage;
      this.pending = false;
    }
  },

  destroyed() {
    if (this.observer) {
      this.observer.disconnect();
    }
  },
};

export default InfiniteScroll;
