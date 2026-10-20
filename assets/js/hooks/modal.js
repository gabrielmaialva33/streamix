const Modal = {
  mounted() {
    if (this.el.dataset.show === "true") {
      this._openWithFocusRestore();
    }

    this.onClose = () => {
      this._restoreFocus();
      this.pushEvent(this.el.dataset.closeEvent || "close_modal", {});
    };
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

    if (this.el.open) this.el.close();
    this._restoreFocus();
    this._previousFocus = null;
  },

  // Stash the trigger so we can restore focus after close. Browsers
  // restore focus from <dialog>.close() automatically, but only if the
  // trigger is still in the DOM — better to remember it ourselves.
  _openWithFocusRestore() {
    this._previousFocus = document.activeElement;
    this.el.showModal();

    const firstFocusable =
      this.el.querySelector(
        'input:not([type="hidden"]):not(:disabled), select:not(:disabled), textarea:not(:disabled)',
      ) ||
      this.el.querySelector(
        'button:not([tabindex="-1"]):not(:disabled), [href], [tabindex]:not([tabindex="-1"])',
      );
    firstFocusable?.focus?.();
  },

  _restoreFocus() {
    // LiveView can replace the trigger while patching. Resolve the stable
    // selector again instead of focusing a detached node or the page body.
    const target = this.el.dataset.returnFocus
      ? document.querySelector(this.el.dataset.returnFocus)
      : this._previousFocus;
    if (target?.isConnected) target.focus();
  },
};

export default Modal;
