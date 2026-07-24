const STORAGE_PREFIX = "streamix:browse-scroll:";
const MAX_AGE_MS = 30 * 60 * 1000;
const MAX_RESTORE_MS = 5000;

function storageKey() {
  return `${STORAGE_PREFIX}${window.location.pathname}${window.location.search}`;
}

function removeSavedPosition() {
  try {
    sessionStorage.removeItem(storageKey());
  } catch {
    // Browsing still works when storage is blocked.
  }
}

const BrowseScrollRestoration = {
  mounted() {
    this.handleNavigationClick = (event) => {
      const navigationTarget = event.target.closest(
        '[phx-click="show_details"], [phx-click="play_movie"], [phx-click="view_series"], .content-card a[href]',
      );

      if (!navigationTarget || !this.el.contains(navigationTarget)) return;

      const card = navigationTarget.closest("[data-content-id]");

      try {
        sessionStorage.setItem(
          storageKey(),
          JSON.stringify({
            y: window.scrollY,
            savedAt: Date.now(),
            contentId: card?.dataset.contentId || null,
            contentType: card?.dataset.contentType || null,
          }),
        );
      } catch {
        // Browsing still works when storage is blocked.
      }
    };

    this.el.addEventListener("click", this.handleNavigationClick, true);
    this.restoreScrollPosition();
  },

  updated() {
    this.restoreScrollPosition();
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleNavigationClick, true);
  },

  restoreScrollPosition() {
    if (this.restoreInProgress) return;

    let saved;

    try {
      saved = JSON.parse(sessionStorage.getItem(storageKey()) || "null");
    } catch {
      removeSavedPosition();
      return;
    }

    if (
      !saved ||
      !Number.isFinite(saved.y) ||
      !Number.isFinite(saved.savedAt) ||
      Date.now() - saved.savedAt > MAX_AGE_MS
    ) {
      removeSavedPosition();
      return;
    }

    this.restoreInProgress = true;
    const deadline = performance.now() + MAX_RESTORE_MS;

    const restore = () => {
      const maxScroll = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
      const card = this.findSavedCard(saved);
      const pageReady = maxScroll >= saved.y || card;

      if (pageReady || performance.now() >= deadline) {
        window.scrollTo({ top: Math.min(saved.y, maxScroll), behavior: "auto" });

        if (card) {
          const focusTarget = card.querySelector("[phx-click], a, button") || card;
          if (!focusTarget.hasAttribute("tabindex") && focusTarget === card) {
            focusTarget.setAttribute("tabindex", "-1");
          }
          focusTarget.focus({ preventScroll: true });
        }

        this.restoreInProgress = false;
        removeSavedPosition();
        return;
      }

      requestAnimationFrame(restore);
    };

    requestAnimationFrame(restore);
  },

  findSavedCard(saved) {
    if (!saved.contentId) return null;

    const candidates = this.el.querySelectorAll("[data-content-id]");
    return Array.from(candidates).find(
      (card) =>
        card.dataset.contentId === String(saved.contentId) &&
        (!saved.contentType || card.dataset.contentType === saved.contentType),
    );
  },
};

export default BrowseScrollRestoration;
