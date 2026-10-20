/** Shared missing/broken-image fallback, including LiveView URL replacements. */
const ImageFallback = {
  mounted() {
    this.setupFallback();
  },
  updated() {
    this.setupFallback();
  },
  setupFallback() {
    this.removeListeners();
    const img = this.el.querySelector("img[data-fallback-target]");
    const fallback = this.el.querySelector("[data-fallback]");
    if (!fallback) return;
    if (!img) {
      fallback.classList.remove("hidden");
      return;
    }
    this._image = img;
    this._errorHandler = () => {
      img.classList.add("hidden");
      fallback.classList.remove("hidden");
    };
    this._loadHandler = () => {
      img.classList.remove("hidden");
      fallback.classList.add("hidden");
    };
    img.addEventListener("error", this._errorHandler);
    img.addEventListener("load", this._loadHandler);
    if (img.complete) {
      if (img.naturalHeight === 0) this._errorHandler();
      else this._loadHandler();
    } else {
      this._loadHandler();
    }
  },
  removeListeners() {
    if (!this._image) return;
    this._image.removeEventListener("error", this._errorHandler);
    this._image.removeEventListener("load", this._loadHandler);
    this._image = null;
  },
  destroyed() {
    this.removeListeners();
  },
};
export default ImageFallback;
