const Modal = {
  mounted() {
    // Show modal when mounted with data-show="true"
    if (this.el.dataset.show === "true") {
      this.el.showModal();
    }

    // Listen for close events
    this.el.addEventListener("close", () => {
      // Trigger the cancel event to sync with LiveView
      this.pushEvent("close_modal", {});
    });

    // Close on backdrop click
    this.el.addEventListener("click", (e) => {
      if (e.target === this.el) {
        this.el.close();
      }
    });

    // Close on Escape
    this.handleKeyDown = (e) => {
      if (e.key === "Escape" && this.el.open) {
        e.preventDefault();
        this.el.close();
      }
    };
    document.addEventListener("keydown", this.handleKeyDown);
  },

  updated() {
    // Handle show/hide on updates
    if (this.el.dataset.show === "true" && !this.el.open) {
      this.el.showModal();
    } else if (this.el.dataset.show === "false" && this.el.open) {
      this.el.close();
    }
  },

  destroyed() {
    if (this.handleKeyDown) {
      document.removeEventListener("keydown", this.handleKeyDown);
    }
  },
};

export default Modal;
