const INTERACTIVE_SELECTOR =
  "button, a, input, select, textarea, label, [role='button'], #player-controls";

export function isPlayerBackgroundTarget(target, ElementImpl = globalThis.Element) {
  return typeof ElementImpl === "function" && target instanceof ElementImpl
    ? !target.closest(INTERACTIVE_SELECTOR)
    : false;
}

export function createMobileControls({
  root,
  controls,
  video,
  playerUI,
  shouldUseNativeControls,
  toggleFullscreen,
  environment = {
    window: globalThis.window,
    navigator: globalThis.navigator,
    Element: globalThis.Element,
  },
  now = Date.now,
}) {
  if (!root || !controls || !video) return { destroy() {} };

  let lastTapTime = 0;
  const isTouchDevice =
    "ontouchstart" in environment.window || environment.navigator.maxTouchPoints > 0;

  const onPlayerClick = (event) => {
    if (shouldUseNativeControls() || !isPlayerBackgroundTarget(event.target, environment.Element)) {
      return;
    }

    event.preventDefault();
    const currentTime = now();

    if (currentTime - lastTapTime < 300) {
      toggleFullscreen();
    } else {
      playerUI.toggleControlsVisibility();
    }

    lastTapTime = currentTime;
  };

  const onTouchStart = () => playerUI.clearHideControlsTimeout();
  const onTouchEnd = () => playerUI.scheduleHideControls();
  const onMouseMove = () => {
    if (!isTouchDevice) {
      playerUI.showControls();
      playerUI.scheduleHideControls();
    }
  };
  const onPlay = () => playerUI.scheduleHideControls();
  const onPause = () => {
    playerUI.showControls();
    playerUI.clearHideControlsTimeout();
  };

  if (isTouchDevice) {
    root.addEventListener("click", onPlayerClick);
    controls.addEventListener("touchstart", onTouchStart, { passive: true });
    controls.addEventListener("touchend", onTouchEnd, { passive: true });
    playerUI.showControls();
    playerUI.scheduleHideControls();
  }

  root.addEventListener("mousemove", onMouseMove);
  video.addEventListener("play", onPlay);
  video.addEventListener("pause", onPause);

  return {
    destroy() {
      root.removeEventListener("click", onPlayerClick);
      root.removeEventListener("mousemove", onMouseMove);
      controls.removeEventListener("touchstart", onTouchStart);
      controls.removeEventListener("touchend", onTouchEnd);
      video.removeEventListener("play", onPlay);
      video.removeEventListener("pause", onPause);
    },
  };
}
