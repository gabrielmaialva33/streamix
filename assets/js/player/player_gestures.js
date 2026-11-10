// Pure gesture decisions, independent of DOM, media engine and timers.
export function nextTapGesture(previous, position, time) {
  const zone = position < 0.4 ? "left" : position >= 0.6 ? "right" : "center";
  const repeatWindowMs = previous?.chaining ? 700 : 300;
  const repeated = previous?.zone === zone && time - previous.time <= repeatWindowMs;
  const action = repeated
    ? zone === "center"
      ? "toggle-play"
      : zone === "left"
        ? "seek-backward"
        : "seek-forward"
    : null;
  return { zone, time, action, chaining: Boolean(action && zone !== "center") };
}

export function pinchFit(initialDistance, distance) {
  if (!(initialDistance > 0)) return null;
  const ratio = distance / initialDistance;
  return ratio >= 1.1 ? "fill" : ratio <= 0.9 ? "fit" : null;
}

export function canShowIdlePause({ paused, live, viewer, blocked, ended }) {
  return paused && !live && !viewer && !blocked && !ended;
}
