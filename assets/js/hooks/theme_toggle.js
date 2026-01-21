export default {
  mounted() {
    this.initTheme();
    this.handleToggle();
  },

  initTheme() {
    // Theme is managed entirely on client (localStorage + classList)
    // No need to notify server
    const savedTheme = localStorage.getItem("theme");
    if (savedTheme === "light") {
      document.documentElement.classList.add("light");
    } else {
      document.documentElement.classList.remove("light");
    }
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
