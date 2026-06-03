export default {
  mounted() {
    this.initTheme();
    // Bind so destroyed() can clean up — even though this.el goes away
    // with the LV update, the bound handler keeps the cleanup symmetric.
    this.onToggle = () => {
      const isLight = document.documentElement.classList.toggle("light");
      const theme = isLight ? "light" : "dark";

      try {
        localStorage.setItem("theme", theme);
      } catch (_e) {
        // Safari Private mode — silent fallback, theme just won't persist.
      }

      window.dispatchEvent(new CustomEvent("theme-change", { detail: { theme } }));
    };

    this.el.addEventListener("click", this.onToggle);
  },

  destroyed() {
    this.el?.removeEventListener("click", this.onToggle);
  },

  initTheme() {
    // Theme is managed entirely on client (localStorage + classList).
    try {
      const savedTheme = localStorage.getItem("theme");
      if (savedTheme === "light") {
        document.documentElement.classList.add("light");
      } else {
        document.documentElement.classList.remove("light");
      }
    } catch (_e) {
      // Safari Private mode — default (dark) stays.
    }
  },
};
