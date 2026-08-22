export const DEFAULT_AUTOMATIC_LOADS = 2;
export const CONSTRAINED_AUTOMATIC_LOADS = 1;

export function parseInfiniteScrollPage(value, fallback = 0) {
  const page = Number.parseInt(value, 10);
  return Number.isInteger(page) && page >= 0 ? page : fallback;
}

export function shouldAvoidSpeculativeCatalogWork(navigatorRef = globalThis.navigator) {
  const connection = navigatorRef?.connection || {};
  const effectiveType = connection.effectiveType || "unknown";
  const deviceMemory = navigatorRef?.deviceMemory || 4;
  const cpuCores = navigatorRef?.hardwareConcurrency || 4;

  return (
    connection.saveData === true ||
    effectiveType === "slow-2g" ||
    effectiveType === "2g" ||
    deviceMemory <= 2 ||
    cpuCores <= 4
  );
}

export function automaticLoadLimit({ configured, navigatorRef = globalThis.navigator } = {}) {
  const explicit = Number.parseInt(configured, 10);
  if (Number.isInteger(explicit) && explicit >= 0) return Math.min(explicit, 10);

  return shouldAvoidSpeculativeCatalogWork(navigatorRef)
    ? CONSTRAINED_AUTOMATIC_LOADS
    : DEFAULT_AUTOMATIC_LOADS;
}

export function automaticPreloadMargin(navigatorRef = globalThis.navigator) {
  return shouldAvoidSpeculativeCatalogWork(navigatorRef) ? 300 : 800;
}

export function infiniteScrollStateKey({ elementId, locationRef = globalThis.location } = {}) {
  const href =
    locationRef?.href ||
    `https://streamix.local${locationRef?.pathname || "/"}${locationRef?.search || ""}`;
  const url = new URL(href, "https://streamix.local");
  url.searchParams.delete("page");
  url.hash = "";

  return `${elementId || "sentinel"}:${url.pathname}${url.search}`;
}
