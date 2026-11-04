function clearTimer(owner, key) {
  if (owner[key] != null) clearTimeout(owner[key]);
  owner[key] = null;
}

function cancelResumeFrame(owner) {
  if (owner._resumeToastFrame != null) {
    globalThis.cancelAnimationFrame?.(owner._resumeToastFrame);
    owner._resumeToastFrame = null;
  }
}

/** Temporary presentation resources owned by PlayerUI. */
export const playerOverlays = {
  showQualityChange(quality) {
    if (this._overlaysDestroyed) return;
    clearTimer(this, "_qualityToastTimeout");
    // Remove existing notification
    const existing = this.container.querySelector(".quality-toast");
    if (existing) existing.remove();

    const toast = document.createElement("div");
    toast.className =
      "quality-toast absolute top-4 right-4 pointer-events-none z-30 animate-fade-in-out";

    // Create using DOM API for security
    const inner = document.createElement("div");
    inner.className =
      "px-3 py-1.5 rounded bg-black/70 backdrop-blur-sm text-white text-sm font-medium flex items-center gap-2";

    // HD icon
    const icon = document.createElement("span");
    icon.className = "text-xs bg-white/20 px-1 rounded";
    icon.textContent = "HD";

    const text = document.createElement("span");
    text.textContent = quality;

    inner.appendChild(icon);
    inner.appendChild(text);
    toast.appendChild(inner);
    this.container.appendChild(toast);

    // Remove after animation
    this._qualityToastTimeout = setTimeout(() => {
      this._qualityToastTimeout = null;
      toast.remove();
    }, 2000);
  },
  showAutoplayBlocked() {
    if (this._overlaysDestroyed) return;
    this.hideLoading({ force: true });
    const overlay = this.container.querySelector("#autoplay-overlay");
    if (overlay) {
      overlay.classList.remove("hidden");
    }
  },
  hideAutoplayBlocked() {
    const overlay = this.container.querySelector("#autoplay-overlay");
    if (overlay) {
      overlay.classList.add("hidden");
    }
  },
  showResumeToast(resumeSeconds, onRestart) {
    if (this._overlaysDestroyed) return;
    clearTimer(this, "_resumeToastHideTimeout");
    cancelResumeFrame(this);
    const toast = this.container.querySelector("#resume-toast");
    const timeText = this.container.querySelector("#resume-time-text");
    const restartBtn = this.container.querySelector("#resume-restart-btn");
    if (!toast) return;

    if (timeText) {
      timeText.textContent = this.formatTime(resumeSeconds);
    }

    if (restartBtn && typeof onRestart === "function") {
      restartBtn.onclick = () => {
        this.hideResumeToast();
        onRestart();
      };
    }

    toast.classList.remove("hidden");
    const rAF = typeof requestAnimationFrame === "function" ? requestAnimationFrame : (cb) => cb();
    this._resumeToastFrame = rAF(() => {
      this._resumeToastFrame = null;
      toast.classList.remove("opacity-0", "-translate-y-2");
    });

    clearTimer(this, "_resumeToastTimeout");
    this._resumeToastTimeout = setTimeout(() => {
      this.hideResumeToast();
    }, 5000);
  },
  hideResumeToast() {
    if (this._overlaysDestroyed) return;
    clearTimer(this, "_resumeToastTimeout");
    clearTimer(this, "_resumeToastHideTimeout");
    cancelResumeFrame(this);
    const toast = this.container.querySelector("#resume-toast");
    if (!toast) return;

    toast.classList.add("opacity-0", "-translate-y-2");
    this._resumeToastHideTimeout = setTimeout(() => {
      this._resumeToastHideTimeout = null;
      toast.classList.add("hidden");
    }, 300);
  },
  showEndedOverlay(onReplay, onBack) {
    if (this._overlaysDestroyed) return;
    const overlay = this.container.querySelector("#ended-overlay");
    const replayBtn = this.container.querySelector("#ended-replay-btn");
    const backBtn = this.container.querySelector("#ended-back-btn");
    if (!overlay) return;

    if (replayBtn && typeof onReplay === "function") {
      replayBtn.onclick = () => {
        this.hideEndedOverlay();
        onReplay();
      };
    }

    if (backBtn && typeof onBack === "function") {
      backBtn.onclick = () => {
        this.hideEndedOverlay();
        onBack();
      };
    }

    overlay.classList.remove("hidden");
  },
  hideEndedOverlay() {
    const overlay = this.container.querySelector("#ended-overlay");
    if (overlay) {
      overlay.classList.add("hidden");
    }
  },
  destroy() {
    this._overlaysDestroyed = true;
    for (const key of ["_qualityToastTimeout", "_resumeToastTimeout", "_resumeToastHideTimeout"]) {
      clearTimer(this, key);
    }
    cancelResumeFrame(this);
    this.container.querySelector(".quality-toast")?.remove();
    for (const id of ["#resume-restart-btn", "#ended-replay-btn", "#ended-back-btn"]) {
      const button = this.container.querySelector(id);
      if (button) button.onclick = null;
    }
  },
};
