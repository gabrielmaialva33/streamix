export default {
  mounted() {
    this.initTheme();
    this.handleToggle();
  },

  initTheme() {
    // Check initial state
    const isLight = document.documentElement.classList.contains("light");
    this.pushEventTo(this.el, "theme_init", { theme: isLight ? "light" : "dark" });
  },

  handleToggle() {
    this.el.addEventListener("click", () => {
      const isLight = document.documentElement.classList.toggle("light");
      const theme = isLight ? "light" : "dark";

      // Persist to localStorage
      localStorage.setItem("theme", theme);

      // Dispatch event for other components (if needed)
      window.dispatchEvent(new CustomEvent("theme-change", { detail: { theme } }));
    });
  }
};
