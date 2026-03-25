/**
 * ImageFallback Hook
 *
 * Handles image load errors in a CSP-compliant way.
 * When an image fails to load, hides it and shows the fallback element.
 *
 * Usage:
 *   <div phx-hook="ImageFallback">
 *     <img src="..." data-fallback-target />
 *     <div data-fallback class="hidden">Fallback content</div>
 *   </div>
 */
const ImageFallback = {
  mounted() {
    this.setupFallback();
  },

  updated() {
    this.setupFallback();
  },

  setupFallback() {
    const img = this.el.querySelector("img[data-fallback-target]");
    const fallback = this.el.querySelector("[data-fallback]");

    if (!img || !fallback) return;

    // Remove any existing listener to avoid duplicates
    if (this._errorHandler) {
      img.removeEventListener("error", this._errorHandler);
    }

    this._errorHandler = () => {
      img.classList.add("hidden");
      fallback.classList.remove("hidden");
    };

    img.addEventListener("error", this._errorHandler);

    // Check if image already failed (cached error state or empty src)
    if (img.complete && img.naturalHeight === 0) {
      this._errorHandler();
    }
  },

  destroyed() {
    const img = this.el.querySelector("img[data-fallback-target]");
    if (img && this._errorHandler) {
      img.removeEventListener("error", this._errorHandler);
    }
  },
};

export default ImageFallback;
