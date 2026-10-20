/**
 * ScrollHeader — scroll-aware header transparency
 *
 * Transparent over a hero at scroll zero, opaque elsewhere.
 * Uses data-scrolled attribute for CSS-driven styling.
 */
const ScrollHeader = {
  mounted() {
    this.header = this.el;
    this.threshold = 0;
    this.ticking = false;

    this.onScroll = () => {
      if (!this.ticking) {
        requestAnimationFrame(() => {
          const scrolled = window.scrollY > this.threshold;
          this.header.dataset.scrolled = scrolled;
          this.ticking = false;
        });
        this.ticking = true;
      }
    };

    window.addEventListener("scroll", this.onScroll, { passive: true });
    // Set initial state
    this.header.dataset.scrolled = window.scrollY > this.threshold;
  },

  updated() {
    this.header.dataset.scrolled = window.scrollY > this.threshold;
  },

  destroyed() {
    window.removeEventListener("scroll", this.onScroll);
  },
};

export default ScrollHeader;
