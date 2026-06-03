const Modal = {
  mounted() {
    if (this.el.dataset.show === "true") {
      this._openWithFocusRestore();
    }

    this.onClose = () => this.pushEvent("close_modal", {});
    this.el.addEventListener("close", this.onClose);

    this.onBackdropClick = (e) => {
      if (e.target === this.el) this.el.close();
    };
    this.el.addEventListener("click", this.onBackdropClick);

    this.handleKeyDown = (e) => {
      if (e.key === "Escape" && this.el.open) {
        e.preventDefault();
        this.el.close();
      }
    };
    document.addEventListener("keydown", this.handleKeyDown);
  },

  updated() {
    if (this.el.dataset.show === "true" && !this.el.open) {
      this._openWithFocusRestore();
    } else if (this.el.dataset.show === "false" && this.el.open) {
      this.el.close();
    }
  },

  destroyed() {
    this.el?.removeEventListener("close", this.onClose);
    this.el?.removeEventListener("click", this.onBackdropClick);

    if (this.handleKeyDown) {
      document.removeEventListener("keydown", this.handleKeyDown);
    }

    // If we still have the trigger reference, hand focus back. Closing
    // a <dialog> normally restores it, but if the modal vanishes via
    // LV destroy (e.g. navigation) the browser doesn't, and the user
    // ends up at the top of the page.
    this._previousFocus?.focus?.();
    this._previousFocus = null;
  },

  // Stash the trigger so we can restore focus after close. Browsers
  // restore focus from <dialog>.close() automatically, but only if the
  // trigger is still in the DOM — better to remember it ourselves.
  _openWithFocusRestore() {
    this._previousFocus = document.activeElement;
    this.el.showModal();

    // Move focus into the first focusable inside the dialog. The
    // default browser behaviour focuses the dialog itself, which
    // screen readers announce as a generic "dialog" with no further
    // context.
    const firstFocusable = this.el.querySelector(
      'button:not([tabindex="-1"]), [href], input:not([type="hidden"]), select, textarea, [tabindex]:not([tabindex="-1"])',
    );
    firstFocusable?.focus?.();
  },
};

export default Modal;
