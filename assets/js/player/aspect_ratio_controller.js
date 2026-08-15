const STORAGE_KEY = "streamix:player:aspect";
const VALID_MODES = new Set(["auto", "cover", "16-9", "4-3", "native"]);

// AVPlayer (libmedia) and h265web each render into their own mount and
// size the canvas themselves, so both need to be re-styled on every mode
// change — see the custom properties in assets/css/platform.css.
const MOUNT_SELECTORS = ["#avplayer-mount", "#h265web-mount"];

export function normalizeAspectMode(mode) {
  return VALID_MODES.has(mode) ? mode : "auto";
}

// `width`/`height` matter for the forced ratios: the media element is
// pinned with `absolute inset-0 w-full h-full`, and `aspect-ratio` is
// ignored while both dimensions are constrained. Releasing them (plus
// `margin: auto` applied by the controller) lets the ratio drive the box
// and keeps it centred inside the player.
export function aspectStyleForMode(mode) {
  switch (normalizeAspectMode(mode)) {
    case "cover":
      return { objectFit: "cover", aspectRatio: "", width: "", height: "" };
    case "16-9":
      return { objectFit: "fill", aspectRatio: "16 / 9", width: "auto", height: "auto" };
    case "4-3":
      return { objectFit: "fill", aspectRatio: "4 / 3", width: "auto", height: "auto" };
    case "native":
      return { objectFit: "none", aspectRatio: "", width: "", height: "" };
    default:
      return { objectFit: "", aspectRatio: "", width: "", height: "" };
  }
}

export function createAspectRatioController({
  root,
  video,
  storage,
  MutationObserverImpl = globalThis.MutationObserver,
}) {
  const clickListeners = [];
  const observers = [];
  let activeMode = "auto";

  const resolveStorage = () => {
    if (storage !== undefined) return storage;

    try {
      return globalThis.localStorage;
    } catch (_) {
      return null;
    }
  };

  const readMode = () => {
    try {
      return normalizeAspectMode(resolveStorage()?.getItem(STORAGE_KEY));
    } catch (_) {
      return "auto";
    }
  };

  // The native <video> can be replaced when the player restarts on a new
  // backend, so it is looked up on every apply instead of being captured
  // once at mount time.
  const collectTargets = () => {
    const targets = new Set();

    if (video) targets.add(video);

    const nativeVideo = root?.querySelector("video");
    if (nativeVideo) targets.add(nativeVideo);

    for (const selector of MOUNT_SELECTORS) {
      const mount = root?.querySelector(selector);
      if (!mount) continue;

      for (const element of mount.querySelectorAll("canvas, video")) {
        targets.add(element);
      }
    }

    return targets;
  };

  const apply = (mode) => {
    const normalizedMode = normalizeAspectMode(mode);
    const style = aspectStyleForMode(normalizedMode);
    const forcedRatio = style.aspectRatio !== "";
    activeMode = normalizedMode;

    for (const element of collectTargets()) {
      element.style.objectFit = style.objectFit;
      element.style.aspectRatio = style.aspectRatio;
      element.style.width = style.width;
      element.style.height = style.height;
      element.style.margin = forcedRatio ? "auto" : "";
      element.style.maxWidth = forcedRatio ? "100%" : "";
      element.style.maxHeight = forcedRatio ? "100%" : "";

      // Canvas-backed players sit behind `!important` sizing rules, which
      // plain inline styles cannot override.
      element.style.setProperty?.("--streamix-player-fit", style.objectFit || "contain");
      element.style.setProperty?.("--streamix-player-width", style.width || "100%");
      element.style.setProperty?.("--streamix-player-height", style.height || "100%");
    }

    root?.querySelectorAll(".aspect-check").forEach((element) => {
      element.classList.toggle("hidden", element.dataset.aspectCheck !== normalizedMode);
    });
  };

  apply(readMode());

  root?.querySelectorAll(".aspect-option").forEach((button) => {
    const onClick = () => {
      const mode = normalizeAspectMode(button.dataset.aspectMode);

      try {
        resolveStorage()?.setItem(STORAGE_KEY, mode);
      } catch (_) {
        // Storage is best-effort; the selected mode still applies to this session.
      }

      apply(mode);
    };

    button.addEventListener("click", onClick);
    clickListeners.push([button, onClick]);
  });

  if (typeof MutationObserverImpl === "function") {
    for (const selector of MOUNT_SELECTORS) {
      const mount = root?.querySelector(selector);
      if (!mount) continue;

      const observer = new MutationObserverImpl(() => apply(activeMode));
      observer.observe(mount, { childList: true, subtree: true });
      observers.push(observer);
    }
  }

  return {
    apply,
    destroy() {
      for (const observer of observers) {
        observer.disconnect();
      }

      observers.length = 0;

      for (const [button, listener] of clickListeners) {
        button.removeEventListener("click", listener);
      }
    },
  };
}
