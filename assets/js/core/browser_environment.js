// Capability predicates stay independent: touch does not imply lack of hover.
export function hasTouch({
  windowRef = globalThis.window,
  navigatorRef = globalThis.navigator,
} = {}) {
  return Boolean((windowRef && "ontouchstart" in windowRef) || navigatorRef?.maxTouchPoints > 0);
}

export function canHover({ windowRef = globalThis.window } = {}) {
  const query = windowRef?.matchMedia?.("(hover: hover) and (pointer: fine)");
  return query ? query.matches : !(windowRef && "ontouchstart" in windowRef);
}

export function isStandalone({
  windowRef = globalThis.window,
  navigatorRef = globalThis.navigator,
} = {}) {
  return (
    navigatorRef?.standalone === true ||
    windowRef?.matchMedia?.("(display-mode: standalone)")?.matches === true
  );
}

export function isAppleTouch({ navigatorRef = globalThis.navigator } = {}) {
  return (
    /iPad|iPhone|iPod/.test(navigatorRef?.userAgent || "") ||
    (navigatorRef?.platform === "MacIntel" && Number(navigatorRef?.maxTouchPoints) > 1)
  );
}
