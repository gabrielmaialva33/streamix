/**
 * HeaderSearch Hook
 * Expandable search input in the header - Netflix style
 */
const HeaderSearch = {
  mounted() {
    this.toggle = this.el.querySelector("#search-toggle");
    this.container = this.el.querySelector("#search-input-container");
    this.input = this.el.querySelector("#header-search-input");
    this.closeBtn = this.el.querySelector("#search-close");
    this.isOpen = false;

    // Toggle search on click
    this.toggle.addEventListener("click", () => this.open());
    this.closeBtn.addEventListener("click", () => this.close());

    // Close on escape key
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && this.isOpen) {
        this.close();
      }
    });

    // Close when clicking outside
    document.addEventListener("click", (e) => {
      if (this.isOpen && !this.el.contains(e.target)) {
        this.close();
      }
    });

    // Submit on enter
    this.input.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && this.input.value.trim()) {
        this.input.closest("form").submit();
      }
    });
  },

  open() {
    this.isOpen = true;
    this.toggle.classList.add("hidden");
    this.container.classList.remove("hidden");
    this.container.classList.add("flex");
    // Small delay to ensure transition works
    requestAnimationFrame(() => {
      this.input.focus();
    });
  },

  close() {
    this.isOpen = false;
    this.container.classList.add("hidden");
    this.container.classList.remove("flex");
    this.toggle.classList.remove("hidden");
    this.input.value = "";
  },
};

export default HeaderSearch;
