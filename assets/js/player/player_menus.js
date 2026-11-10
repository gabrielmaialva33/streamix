import { createFocusTrap } from "../core/focus_trap.js";

/** Menu focus and observer resources owned by PlayerUI. */
export const playerMenus = {
  setupMenuFocusTraps() {
    // Speed menu
    const speedMenu = this.container.querySelector("#speed-menu");
    const speedBtn = this.container.querySelector("#speed-btn");
    if (speedMenu && speedBtn) {
      this.setupMenuFocusTrap(speedMenu, speedBtn, "speed");
    }

    // Settings menu
    const settingsMenu = this.container.querySelector("#settings-menu");
    const settingsBtn = this.container.querySelector("#settings-btn");
    if (settingsMenu && settingsBtn) {
      this.setupMenuFocusTrap(settingsMenu, settingsBtn, "settings");
    }

    // Tracks menu
    const tracksMenu = this.container.querySelector("#tracks-menu");
    const tracksBtn = this.container.querySelector("#tracks-btn");
    if (tracksMenu && tracksBtn) {
      this.setupMenuFocusTrap(tracksMenu, tracksBtn, "tracks");
    }
  },
  setupMenuFocusTrap(menu, triggerBtn, name) {
    const focusTrap = createFocusTrap(menu, {
      returnFocusTo: triggerBtn,
      onEscape: () => {
        menu.classList.add("hidden");
        menu.style.display = "none";
        triggerBtn.setAttribute("aria-expanded", "false");
      },
    });

    this.focusTraps.set(name, focusTrap);

    const checkVisibility = () => {
      const isHidden =
        menu.classList.contains("hidden") ||
        menu.style.display === "none" ||
        (typeof window !== "undefined" && window.getComputedStyle
          ? window.getComputedStyle(menu).display === "none"
          : false);

      if (isHidden) {
        focusTrap.deactivate();
        triggerBtn.setAttribute("aria-expanded", "false");
      } else {
        focusTrap.activate();
        triggerBtn.setAttribute("aria-expanded", "true");
      }
    };

    // Use MutationObserver to detect when menu visibility changes
    const observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        if (mutation.attributeName === "class" || mutation.attributeName === "style") {
          checkVisibility();
        }
      }
    });

    observer.observe(menu, { attributes: true, attributeFilter: ["class", "style"] });

    // Store observer for cleanup
    if (!this._menuObservers) {
      this._menuObservers = [];
    }
    this._menuObservers.push(observer);
  },
  destroy() {
    // Cleanup focus traps
    for (const focusTrap of this.focusTraps.values()) {
      focusTrap.deactivate();
    }
    this.focusTraps.clear();

    // Cleanup mutation observers
    if (this._menuObservers) {
      for (const observer of this._menuObservers) {
        observer.disconnect();
      }
      this._menuObservers = [];
    }
  },
};
