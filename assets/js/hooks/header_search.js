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

    // Bind handlers so `removeEventListener` in `destroyed()` can find
    // the same function reference. Previously the inline `() => …`
    // arrow functions had no anchor and leaked on every re-mount.
    this.onToggleClick = () => this.open();
    this.onCloseClick = () => this.close();

    this.onDocKeydown = (e) => {
      if (e.key === "Escape" && this.isOpen) {
        this.close();
      }
    };

    this.onDocClick = (e) => {
      if (this.isOpen && !this.el.contains(e.target)) {
        this.close();
      }
    };

    this.onInputKeydown = (e) => {
      if (e.key === "Enter" && this.input.value.trim()) {
        this.input.closest("form").submit();
      }
    };

    this.toggle.addEventListener("click", this.onToggleClick);
    this.closeBtn.addEventListener("click", this.onCloseClick);
    document.addEventListener("keydown", this.onDocKeydown);
    document.addEventListener("click", this.onDocClick);
    this.input.addEventListener("keydown", this.onInputKeydown);
  },

  destroyed() {
    // document-level listeners would otherwise stack across LV updates.
    this.toggle?.removeEventListener("click", this.onToggleClick);
    this.closeBtn?.removeEventListener("click", this.onCloseClick);
    document.removeEventListener("keydown", this.onDocKeydown);
    document.removeEventListener("click", this.onDocClick);
    this.input?.removeEventListener("keydown", this.onInputKeydown);
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
