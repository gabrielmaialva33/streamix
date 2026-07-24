const STORAGE_PREFIX = "streamix:browse-scroll:";
const MAX_AGE_MS = 30 * 60 * 1000;
const MAX_RESTORE_FRAMES = 30;

function storageKey() {
  return `${STORAGE_PREFIX}${window.location.pathname}${window.location.search}`;
}

const BrowseScrollRestoration = {
  mounted() {
    this.handleNavigationClick = (event) => {
      const navigationTarget = event.target.closest(
        '[phx-click="show_details"], [phx-click="play_movie"], [phx-click="view_series"]',
      );

      if (!navigationTarget || !this.el.contains(navigationTarget)) return;

      try {
        sessionStorage.setItem(
          storageKey(),
          JSON.stringify({ y: window.scrollY, savedAt: Date.now() }),
        );
      } catch {
        // Browsing still works when storage is blocked.
      }
    };

    this.el.addEventListener("click", this.handleNavigationClick, true);
    this.restoreScrollPosition();
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleNavigationClick, true);
  },

  restoreScrollPosition() {
    let saved;

    try {
      saved = JSON.parse(sessionStorage.getItem(storageKey()) || "null");
      sessionStorage.removeItem(storageKey());
    } catch {
      return;
    }

    if (
      !saved ||
      !Number.isFinite(saved.y) ||
      !Number.isFinite(saved.savedAt) ||
      Date.now() - saved.savedAt > MAX_AGE_MS
    ) {
      return;
    }

    let frame = 0;
    const restore = () => {
      const maxScroll = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);

      if (maxScroll >= saved.y || frame >= MAX_RESTORE_FRAMES) {
        window.scrollTo({ top: Math.min(saved.y, maxScroll), behavior: "auto" });
        return;
      }

      frame += 1;
      requestAnimationFrame(restore);
    };

    requestAnimationFrame(restore);
  },
};

export default BrowseScrollRestoration;
