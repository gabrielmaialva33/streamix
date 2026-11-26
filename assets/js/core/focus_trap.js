/**
 * Focus Trap Utility
 *
 * Traps focus within a container element for accessibility.
 * Used for modal dialogs and dropdown menus.
 */

const FOCUSABLE_SELECTORS = [
  "button:not([disabled])",
  "a[href]",
  "input:not([disabled])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  '[tabindex]:not([tabindex="-1"])',
].join(",");

/**
 * Create a focus trap for a container element
 * @param {HTMLElement} container - The element to trap focus within
 * @param {Object} options - Configuration options
 * @param {function} [options.onEscape] - Callback when Escape is pressed
 * @param {HTMLElement} [options.returnFocusTo] - Element to return focus to on close
 * @param {boolean} [options.closeOnClickOutside=true] - Close when clicking outside
 * @returns {Object} Focus trap controller with activate/deactivate methods
 */
export function createFocusTrap(container, options = {}) {
  const {
    closeOnClickOutside = true,
    onEscape,
    returnFocusTo,
    documentRef = globalThis.document,
    scheduler = globalThis,
  } = options;

  let active = false;
  let previouslyFocused = null;
  let focusFrame = null;

  /**
   * Get all focusable elements within the container
   */
  function getFocusableElements() {
    return Array.from(container.querySelectorAll(FOCUSABLE_SELECTORS)).filter(
      (el) => el.offsetParent !== null,
    ); // Filter out hidden elements
  }

  /**
   * Handle keydown events for focus trapping
   */
  function handleKeyDown(e) {
    if (!active) return;

    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      // Let the owner restore an inert background before returning focus.
      onEscape?.();
      deactivate();
      return;
    }

    if (e.key !== "Tab") return;

    const focusableElements = getFocusableElements();
    if (focusableElements.length === 0) return;

    const firstElement = focusableElements[0];
    const lastElement = focusableElements[focusableElements.length - 1];

    // Shift + Tab: going backwards
    if (e.shiftKey) {
      if (
        documentRef.activeElement === firstElement ||
        !container.contains(documentRef.activeElement)
      ) {
        e.preventDefault();
        lastElement.focus();
      }
    } else {
      // Tab: going forwards
      if (
        documentRef.activeElement === lastElement ||
        !container.contains(documentRef.activeElement)
      ) {
        e.preventDefault();
        firstElement.focus();
      }
    }
  }

  /**
   * Handle click outside the container
   */
  function handleClickOutside(e) {
    if (!active || !closeOnClickOutside) return;

    if (!container.contains(e.target)) {
      // Let the owner restore an inert background before returning focus.
      onEscape?.();
      deactivate();
    }
  }

  /**
   * Activate the focus trap
   */
  function activate() {
    if (active) return;

    active = true;
    previouslyFocused = returnFocusTo || documentRef.activeElement;

    // Add event listeners
    documentRef.addEventListener("keydown", handleKeyDown, true);
    documentRef.addEventListener("mousedown", handleClickOutside, true);

    // Focus the first focusable element
    const focusableElements = getFocusableElements();
    if (focusableElements.length > 0) {
      // Small delay to ensure the container is visible
      focusFrame = scheduler.requestAnimationFrame(() => {
        focusFrame = null;
        if (active) focusableElements[0].focus();
      });
    }

    // Set aria-modal for screen readers
    container.setAttribute("aria-modal", "true");
    container.setAttribute("role", "dialog");
  }

  /**
   * Deactivate the focus trap
   */
  function deactivate() {
    if (!active) return;

    active = false;
    if (focusFrame !== null) scheduler.cancelAnimationFrame(focusFrame);
    focusFrame = null;

    // Remove event listeners
    documentRef.removeEventListener("keydown", handleKeyDown, true);
    documentRef.removeEventListener("mousedown", handleClickOutside, true);

    // Remove ARIA attributes
    container.removeAttribute("aria-modal");
    container.removeAttribute("role");

    // Return focus to the previous element
    if (previouslyFocused && typeof previouslyFocused.focus === "function") {
      previouslyFocused.focus();
    }

    previouslyFocused = null;
  }

  /**
   * Check if the focus trap is active
   */
  function isActive() {
    return active;
  }

  return {
    activate,
    deactivate,
    isActive,
  };
}

export default createFocusTrap;
