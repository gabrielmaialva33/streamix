export const hasWebCodecsHevcSupport = (windowRef = globalThis.window) =>
  typeof windowRef?.VideoDecoder === "function";

export function readEngineFlag(containerEl, engine, storage) {
  const dataKey = `feature${engine.charAt(0).toUpperCase()}${engine.slice(1)}`;
  if (containerEl?.dataset?.[dataKey] === "true") return true;

  try {
    const flagStorage = storage ?? globalThis.localStorage;
    return flagStorage?.getItem(`streamix:${engine}`) === "true";
  } catch {
    // Locked-down browser storage means the experimental engine stays disabled.
    return false;
  }
}

export const isFirefoxBrowser = (navigatorRef = globalThis.navigator) =>
  /firefox/i.test(navigatorRef?.userAgent || "");

export function isAppleTouchDevice(navigatorRef = globalThis.navigator) {
  const userAgent = navigatorRef?.userAgent || "";
  const platform = navigatorRef?.platform || "";

  return (
    /iPad|iPhone|iPod/.test(userAgent) ||
    (platform === "MacIntel" && Number(navigatorRef?.maxTouchPoints) > 1)
  );
}

export function isStandalonePwa({
  navigatorRef = globalThis.navigator,
  windowRef = globalThis.window,
} = {}) {
  return (
    navigatorRef?.standalone === true ||
    windowRef?.matchMedia?.("(display-mode: standalone)")?.matches === true
  );
}

export function isIosPwaMode(environment = {}) {
  return isAppleTouchDevice(environment.navigatorRef) && isStandalonePwa(environment);
}

export function scheduleLowPriority(
  callback,
  { timeout = 2500, windowRef = globalThis.window } = {},
) {
  if (typeof windowRef?.requestIdleCallback === "function") {
    const id = windowRef.requestIdleCallback(callback, { timeout });
    return () => windowRef.cancelIdleCallback?.(id);
  }

  const id = windowRef.setTimeout(callback, Math.min(timeout, 1000));
  return () => windowRef.clearTimeout(id);
}

export function getPlaybackResourcePolicy(navigatorRef = globalThis.navigator) {
  const connection = navigatorRef?.connection || {};
  const saveData = connection.saveData === true;
  const effectiveType = connection.effectiveType || "unknown";
  const deviceMemory = navigatorRef?.deviceMemory || 4;
  const cpuCores = navigatorRef?.hardwareConcurrency || 4;
  const lowEndDevice = deviceMemory <= 2 || cpuCores <= 4;
  const constrainedNetwork = effectiveType === "slow-2g" || effectiveType === "2g";
  const avoidSpeculativeWork = saveData || constrainedNetwork || lowEndDevice;

  return {
    saveData,
    effectiveType,
    deviceMemory,
    cpuCores,
    lowEndDevice,
    constrainedNetwork,
    avoidSpeculativeWork,
    shouldRunAdvancedDiagnostics: !avoidSpeculativeWork,
    shouldProbeTracks: !saveData && !constrainedNetwork,
    reason: saveData
      ? "save-data"
      : constrainedNetwork
        ? `network-${effectiveType}`
        : lowEndDevice
          ? "low-end-device"
          : "normal",
  };
}
