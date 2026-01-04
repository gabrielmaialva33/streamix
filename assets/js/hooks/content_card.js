/**
 * Content Card Hook
 *
 * Handles pre-loading optimization for content cards.
 * Pre-loads AVPlayer WASM on hover for faster playback startup.
 *
 * Netflix-inspired: Pre-load resources before user clicks to
 * reduce time-to-first-frame when playback starts.
 */

// Track if we've already preloaded
let hasPreloaded = false;

// Lazy import for preload function
let preloadAVPlayerWasm = null;

async function ensurePreloadFunctionLoaded() {
  if (!preloadAVPlayerWasm) {
    const module = await import("../lib/avplayer_wrapper");
    preloadAVPlayerWasm = module.preloadCommonWasm;
  }
  return preloadAVPlayerWasm;
}

const ContentCard = {
  mounted() {
    // Get content type from data attributes
    this.sourceType = this.el.dataset.sourceType;
    this.contentType = this.el.dataset.contentType;

    // Add hover listener for pre-loading
    this.hoverHandler = () => this.handleHover();
    this.el.addEventListener("mouseenter", this.hoverHandler, { once: true });

    // Also handle focus for keyboard navigation
    this.focusHandler = () => this.handleHover();
    this.el.addEventListener("focus", this.focusHandler, { once: true });

    // Use Intersection Observer for "about to be visible" pre-loading
    this.setupIntersectionObserver();
  },

  destroyed() {
    this.el.removeEventListener("mouseenter", this.hoverHandler);
    this.el.removeEventListener("focus", this.focusHandler);

    if (this.observer) {
      this.observer.disconnect();
    }
  },

  /**
   * Handle hover event - pre-load AVPlayer for GIndex/MKV content
   */
  async handleHover() {
    // Only preload once per session
    if (hasPreloaded) return;

    // Only preload for content types that might need AVPlayer
    const needsPreload = this.sourceType === "gindex" || this.contentType === "vod";

    if (needsPreload) {
      try {
        const preload = await ensurePreloadFunctionLoaded();
        if (preload && !hasPreloaded) {
          hasPreloaded = true;
          console.log("[ContentCard] Pre-loading AVPlayer WASM on hover");
          preload();
        }
      } catch (e) {
        // Silent failure - pre-loading is optional optimization
        console.debug("[ContentCard] Pre-load failed:", e.message);
      }
    }
  },

  /**
   * Use Intersection Observer for viewport-based pre-loading
   * Pre-load when content cards are about to become visible
   */
  setupIntersectionObserver() {
    // Only set up once per page
    if (hasPreloaded) return;

    const options = {
      root: null, // viewport
      rootMargin: "200px", // Pre-load when 200px from viewport
      threshold: 0,
    };

    this.observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting && !hasPreloaded) {
          // Content is about to be visible, pre-load in background
          this.handleHover();
          this.observer.disconnect();
          break;
        }
      }
    }, options);

    this.observer.observe(this.el);
  },
};

export default ContentCard;
