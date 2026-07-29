const SURFACE_RULES = [
  [/^\/(?:home)?$/, "home"],
  [/^\/(?:browse|providers|gindex|torrent|search)/, "browse"],
  [/^\/watch\//, "watch"],
  [/^\/party/, "party"],
  [/^\/favorites/, "favorites"],
  [/^\/history/, "history"],
  [/^\/(?:login|register)/, "auth"],
  [/^\/(?:settings|billing)/, "settings"],
  [/^\/admin/, "admin"],
];

const boundedMetric = (value, maximum) => {
  if (!Number.isFinite(value)) return undefined;
  return Math.min(Math.max(Math.round(value), 0), maximum);
};

export const surfaceForPath = (path = "/") => {
  const pathname = String(path).split(/[?#]/, 1)[0];
  return SURFACE_RULES.find(([pattern]) => pattern.test(pathname))?.[1] || "other";
};

export const webVitalPayload = ({ batchId, path, displayMode = "browser", lcp, inp, cls }) => {
  const payload = {
    batch_id: batchId,
    kind: "web_vital",
    event: "page_vitals",
    surface: surfaceForPath(path),
    display_mode: displayMode === "standalone" ? "standalone" : "browser",
  };

  const lcpMs = boundedMetric(lcp, 86_400_000);
  const inpMs = boundedMetric(inp, 86_400_000);
  const clsMilli = boundedMetric(Number.isFinite(cls) ? cls * 1000 : undefined, 1_000_000);

  if (lcpMs !== undefined) payload.lcp_ms = lcpMs;
  if (inpMs !== undefined) payload.inp_ms = inpMs;
  if (clsMilli !== undefined) payload.cls_milli = clsMilli;

  return payload;
};
