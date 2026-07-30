const STORAGE_KEY = "streamix:player:aspect";
const VALID_MODES = new Set(["auto", "cover", "16-9", "4-3", "native"]);

export function normalizeAspectMode(mode) {
  return VALID_MODES.has(mode) ? mode : "auto";
}

export function aspectStyleForMode(mode) {
  switch (normalizeAspectMode(mode)) {
    case "cover":
      return { objectFit: "cover", aspectRatio: "" };
    case "16-9":
      return { objectFit: "contain", aspectRatio: "16 / 9" };
    case "4-3":
      return { objectFit: "contain", aspectRatio: "4 / 3" };
    case "native":
      return { objectFit: "none", aspectRatio: "" };
    default:
      return { objectFit: "", aspectRatio: "" };
  }
}

export function createAspectRatioController({
  root,
  video,
  storage,
  MutationObserverImpl = globalThis.MutationObserver,
}) {
  const clickListeners = [];
  let observer = null;
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

  const apply = (mode) => {
    const normalizedMode = normalizeAspectMode(mode);
    const style = aspectStyleForMode(normalizedMode);
    const targets = [];
    activeMode = normalizedMode;

    if (video) targets.push(video);

    const mount = root?.querySelector("#avplayer-mount");
    if (mount) targets.push(...mount.querySelectorAll("canvas, video"));

    for (const element of targets) {
      element.style.objectFit = style.objectFit;
      element.style.aspectRatio = style.aspectRatio;
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

  const mount = root?.querySelector("#avplayer-mount");
  if (mount && typeof MutationObserverImpl === "function") {
    observer = new MutationObserverImpl(() => apply(activeMode));
    observer.observe(mount, { childList: true, subtree: true });
  }

  return {
    apply,
    destroy() {
      observer?.disconnect();
      observer = null;

      for (const [button, listener] of clickListeners) {
        button.removeEventListener("click", listener);
      }
    },
  };
}
