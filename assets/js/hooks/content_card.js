/**
 * Content Card Hook - Netflix-style Hover Preview
 *
 * Features:
 * - Delayed expansion (~600ms) to prevent accidental triggers
 * - Expanded preview with title, rating, year, plot, action buttons
 * - Smart positioning to avoid viewport edges
 * - Touch device support (tap to expand, tap outside to close)
 * - WASM pre-loading for faster playback startup
 */

// Track if we've already preloaded WASM
let hasPreloadedWasm = false;

// Lazy import for preload function
let preloadAVPlayerWasm = null;

async function ensurePreloadFunctionLoaded() {
  if (!preloadAVPlayerWasm) {
    try {
      const module = await import("../lib/avplayer_wrapper");
      preloadAVPlayerWasm = module.preloadCommonWasm;
    } catch (_e) {
      // Module may not exist yet
    }
  }
  return preloadAVPlayerWasm;
}

// Track the currently active preview instance (weak reference to avoid cross-instance races)
let activePreviewInstance = null;

// Close any active preview (called via the owning instance)
function closeActivePreview() {
  if (activePreviewInstance) {
    activePreviewInstance._closePreview();
  }
}

// Close preview on escape key
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    closeActivePreview();
  }
});

// Close preview on scroll
document.addEventListener(
  "scroll",
  () => {
    closeActivePreview();
  },
  { passive: true },
);

const ContentCard = {
  mounted() {
    // Instance-level preview state (not shared globals)
    this.activePreview = null;
    this.previewTimeout = null;

    // Get content data from attributes
    this.contentId = this.el.dataset.contentId;
    this.contentType = this.el.dataset.contentType; // movie, series
    this.sourceType = this.el.dataset.sourceType; // iptv, gindex
    this.providerId = this.el.dataset.providerId;

    // Content metadata for preview
    this.title = this.el.dataset.title;
    this.year = this.el.dataset.year;
    this.rating = this.el.dataset.rating;
    this.plot = this.el.dataset.plot;
    this.cover = this.el.dataset.cover;
    this.genre = this.el.dataset.genre;
    this.duration = this.el.dataset.duration;
    this.isFavorite = this.el.dataset.favorite === "true";

    // Hover delay (Netflix uses ~600ms)
    this.hoverDelay = 600;
    this.isTouch = "ontouchstart" in window;

    // Bind handlers
    this.handleMouseEnter = this.handleMouseEnter.bind(this);
    this.handleMouseLeave = this.handleMouseLeave.bind(this);
    this.handleTouchStart = this.handleTouchStart.bind(this);
    this.handleFocus = this.handleFocus.bind(this);

    // Add event listeners
    if (this.isTouch) {
      this.el.addEventListener("touchstart", this.handleTouchStart, { passive: true });
    } else {
      this.el.addEventListener("mouseenter", this.handleMouseEnter);
      this.el.addEventListener("mouseleave", this.handleMouseLeave);
      this.el.addEventListener("focus", this.handleFocus);
    }

    // Intersection observer for WASM preloading
    this.setupIntersectionObserver();
  },

  destroyed() {
    this.el.removeEventListener("mouseenter", this.handleMouseEnter);
    this.el.removeEventListener("mouseleave", this.handleMouseLeave);
    this.el.removeEventListener("focus", this.handleFocus);
    this.el.removeEventListener("touchstart", this.handleTouchStart);

    if (this.observer) {
      this.observer.disconnect();
    }

    // Always clear pending timeout, regardless of pendingPreview flag
    if (this.previewTimeout) {
      clearTimeout(this.previewTimeout);
      this.previewTimeout = null;
    }
    this.pendingPreview = false;

    // Close preview if it belongs to this card
    if (this.activePreview) {
      this._closePreview();
    }
    if (activePreviewInstance === this) {
      activePreviewInstance = null;
    }
  },

  handleMouseEnter() {
    this.pendingPreview = true;

    // Cancel any existing timeout
    if (this.previewTimeout) {
      clearTimeout(this.previewTimeout);
    }

    // Start WASM preload immediately
    this.preloadWasm();

    // Delay before showing preview
    this.previewTimeout = setTimeout(() => {
      this.previewTimeout = null;
      if (this.pendingPreview) {
        this.showPreview();
      }
    }, this.hoverDelay);
  },

  handleMouseLeave() {
    this.pendingPreview = false;

    if (this.previewTimeout) {
      clearTimeout(this.previewTimeout);
      this.previewTimeout = null;
    }

    // Close preview if we're not hovering over it
    setTimeout(() => {
      if (
        this.activePreview &&
        !this.activePreview.matches(":hover") &&
        !this.el.matches(":hover")
      ) {
        this._closePreview();
      }
    }, 100);
  },

  handleFocus() {
    this.preloadWasm();
  },

  handleTouchStart(_e) {
    // On touch, tap toggles preview
    if (this.activePreview) {
      this._closePreview();
    } else {
      closeActivePreview(); // Close any other instance's preview
      this.showPreview();
    }
  },

  _closePreview() {
    if (this.activePreview) {
      this.activePreview.remove();
      this.activePreview = null;
    }
    if (this.previewTimeout) {
      clearTimeout(this.previewTimeout);
      this.previewTimeout = null;
    }
    if (activePreviewInstance === this) {
      activePreviewInstance = null;
    }
  },

  showPreview() {
    try {
      closeActivePreview(); // Close any other instance's preview
      this._closePreview(); // Close our own if lingering

      // Don't show preview if no metadata
      if (!this.title && !this.plot) {
        return;
      }

      const card = this.el;
      const rect = card.getBoundingClientRect();
      const viewportWidth = window.innerWidth;
      const viewportHeight = window.innerHeight;

      // Create preview element
      const preview = document.createElement("div");
      preview.dataset.contentId = this.contentId;
      preview.className =
        "content-preview fixed z-50 bg-surface rounded-lg shadow-2xl overflow-hidden transition-all duration-200 ease-out";
      preview.style.cssText = `
        width: ${Math.min(rect.width * 1.5, 380)}px;
        opacity: 0;
        transform: scale(0.95);
      `;

      // Build preview HTML
      preview.innerHTML = this.buildPreviewHTML();

      // Add to DOM
      document.body.appendChild(preview);
      this.activePreview = preview;
      activePreviewInstance = this;

      // Calculate position
      const previewRect = preview.getBoundingClientRect();
      let left = rect.left + (rect.width - previewRect.width) / 2;
      let top = rect.top - 10;

      // Adjust for viewport edges
      const padding = 16;

      // Horizontal bounds
      if (left < padding) {
        left = padding;
      } else if (left + previewRect.width > viewportWidth - padding) {
        left = viewportWidth - previewRect.width - padding;
      }

      // Vertical bounds - prefer above, fallback to below
      if (top - previewRect.height < padding) {
        top = rect.bottom + 10;
      } else {
        top = top - previewRect.height;
      }

      // Ensure doesn't go below viewport
      if (top + previewRect.height > viewportHeight - padding) {
        top = viewportHeight - previewRect.height - padding;
      }

      preview.style.left = `${left}px`;
      preview.style.top = `${top}px`;

      // Animate in
      requestAnimationFrame(() => {
        preview.style.opacity = "1";
        preview.style.transform = "scale(1)";
      });

      // Add event listeners for preview
      preview.addEventListener("mouseleave", () => {
        setTimeout(() => {
          if (!this.el.matches(":hover") && !preview.matches(":hover")) {
            this._closePreview();
          }
        }, 100);
      });

      // Bind action buttons
      this.bindPreviewActions(preview);
    } catch {
      // Clean up on error to prevent orphaned DOM elements
      this._closePreview();
      // preview error, cleaned up
    }
  },

  buildPreviewHTML() {
    const ratingStars = this.rating
      ? `
      <span class="flex items-center gap-1 text-yellow-400">
        <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 20 20">
          <path d="M9.049 2.927c.3-.921 1.603-.921 1.902 0l1.07 3.292a1 1 0 00.95.69h3.462c.969 0 1.371 1.24.588 1.81l-2.8 2.034a1 1 0 00-.364 1.118l1.07 3.292c.3.921-.755 1.688-1.54 1.118l-2.8-2.034a1 1 0 00-1.175 0l-2.8 2.034c-.784.57-1.838-.197-1.539-1.118l1.07-3.292a1 1 0 00-.364-1.118L2.98 8.72c-.783-.57-.38-1.81.588-1.81h3.461a1 1 0 00.951-.69l1.07-3.292z"/>
        </svg>
        ${this.escapeHtml(this.rating)}
      </span>
    `
      : "";

    const metadata = [this.year, this.genre, this.duration]
      .filter(Boolean)
      .map((v) => this.escapeHtml(v))
      .join(" &bull; ");

    const plotText = this.plot
      ? `<p class="text-sm text-text-secondary line-clamp-3 leading-relaxed">${this.escapeHtml(this.plot)}</p>`
      : "";

    const heartIcon = this.isFavorite
      ? `<svg class="w-5 h-5 text-red-500" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M3.172 5.172a4 4 0 015.656 0L10 6.343l1.172-1.171a4 4 0 115.656 5.656L10 17.657l-6.828-6.829a4 4 0 010-5.656z" clip-rule="evenodd"/></svg>`
      : `<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4.318 6.318a4.5 4.5 0 000 6.364L12 20.364l7.682-7.682a4.5 4.5 0 00-6.364-6.364L12 7.636l-1.318-1.318a4.5 4.5 0 00-6.364 0z"/></svg>`;

    return `
      <div class="relative">
        ${
          this.cover
            ? `
          <div class="aspect-video bg-surface-hover overflow-hidden">
            <img src="${this.escapeHtml(this.cover)}" alt="${this.escapeHtml(this.title)}" class="w-full h-full object-cover" />
            <div class="absolute inset-0 bg-gradient-to-t from-surface via-transparent to-transparent"></div>
          </div>
        `
            : `
          <div class="aspect-video bg-gradient-to-br from-zinc-800 to-zinc-900 flex items-center justify-center">
            <svg class="w-12 h-12 text-zinc-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 4v16M17 4v16M3 8h4m10 0h4M3 12h18M3 16h4m10 0h4M4 20h16a1 1 0 001-1V5a1 1 0 00-1-1H4a1 1 0 00-1 1v14a1 1 0 001 1z"/>
            </svg>
          </div>
        `
        }
      </div>

      <div class="p-4 space-y-3">
        <div class="space-y-1">
          <h3 class="font-semibold text-text-primary text-lg leading-tight">${this.escapeHtml(this.title)}</h3>
          <div class="flex items-center gap-3 text-xs text-text-secondary">
            ${ratingStars}
            ${metadata ? `<span>${metadata}</span>` : ""}
          </div>
        </div>

        ${plotText}

        <div class="flex items-center gap-2 pt-2">
          <button
            data-action="play"
            class="flex-1 flex items-center justify-center gap-2 px-4 py-2.5 bg-brand text-white font-medium rounded-md hover:bg-brand-hover transition-colors"
          >
            <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20">
              <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM9.555 7.168A1 1 0 008 8v4a1 1 0 001.555.832l3-2a1 1 0 000-1.664l-3-2z" clip-rule="evenodd"/>
            </svg>
            Assistir
          </button>
          <button
            data-action="favorite"
            class="p-2.5 rounded-md bg-surface-hover hover:bg-surface border border-border transition-colors"
          >
            ${heartIcon}
          </button>
          <button
            data-action="details"
            class="p-2.5 rounded-md bg-surface-hover hover:bg-surface border border-border transition-colors"
          >
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
            </svg>
          </button>
        </div>
      </div>
    `;
  },

  bindPreviewActions(preview) {
    const playBtn = preview.querySelector('[data-action="play"]');
    const favoriteBtn = preview.querySelector('[data-action="favorite"]');
    const detailsBtn = preview.querySelector('[data-action="details"]');

    if (playBtn) {
      playBtn.addEventListener("click", (e) => {
        e.stopPropagation();
        closeActivePreview();
        // Trigger Phoenix event
        if (this.contentType === "movie") {
          this.pushEvent("play_movie", { id: this.contentId, provider_id: this.providerId });
        } else {
          this.pushEvent("view_series", { id: this.contentId });
        }
      });
    }

    if (favoriteBtn) {
      favoriteBtn.addEventListener("click", (e) => {
        e.stopPropagation();
        this.pushEvent("toggle_favorite", { id: this.contentId, type: this.contentType });
        // Update visual state
        this.isFavorite = !this.isFavorite;
        favoriteBtn.innerHTML = this.isFavorite
          ? `<svg class="w-5 h-5 text-red-500" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M3.172 5.172a4 4 0 015.656 0L10 6.343l1.172-1.171a4 4 0 115.656 5.656L10 17.657l-6.828-6.829a4 4 0 010-5.656z" clip-rule="evenodd"/></svg>`
          : `<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4.318 6.318a4.5 4.5 0 000 6.364L12 20.364l7.682-7.682a4.5 4.5 0 00-6.364-6.364L12 7.636l-1.318-1.318a4.5 4.5 0 00-6.364 0z"/></svg>`;
      });
    }

    if (detailsBtn) {
      detailsBtn.addEventListener("click", (e) => {
        e.stopPropagation();
        closeActivePreview();
        this.pushEvent("show_details", { id: this.contentId, provider_id: this.providerId });
      });
    }
  },

  escapeHtml(text) {
    if (!text) return "";
    return String(text)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#039;");
  },

  async preloadWasm() {
    if (hasPreloadedWasm) return;

    const needsPreload = this.sourceType === "gindex" || this.contentType === "vod";
    if (!needsPreload) return;

    try {
      const preload = await ensurePreloadFunctionLoaded();
      if (preload && !hasPreloadedWasm) {
        hasPreloadedWasm = true;
        // pre-loading AVPlayer WASM
        preload();
      }
    } catch {
      // pre-load failed, non-critical
    }
  },

  setupIntersectionObserver() {
    if (hasPreloadedWasm) return;
    // Idempotent — if mounted() re-runs (LV update / scroll re-render),
    // disconnect the previous observer so we don't accumulate one per
    // re-mount.
    if (this.observer) {
      this.observer.disconnect();
    }

    const options = {
      root: null,
      rootMargin: "200px",
      threshold: 0,
    };

    this.observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting && !hasPreloadedWasm) {
          this.preloadWasm();
          this.observer.disconnect();
          break;
        }
      }
    }, options);

    this.observer.observe(this.el);
  },

  destroyed() {
    if (this.observer) {
      this.observer.disconnect();
      this.observer = null;
    }
    if (this.handleTouchStart) {
      this.el.removeEventListener("touchstart", this.handleTouchStart);
    }
  },
};

export default ContentCard;
