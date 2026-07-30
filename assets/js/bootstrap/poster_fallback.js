const POSTER_FALLBACK_SRC = "/images/poster-fallback.svg";

export function installPosterFallback() {
  // `error` does not bubble, so delegation must use the capture phase.
  document.addEventListener(
    "error",
    (event) => {
      const target = event.target;
      if (!(target instanceof HTMLImageElement)) return;
      if (target.matches("[data-fallback-target]")) return;
      if (target.dataset.fallbackApplied === "1") return;

      target.dataset.fallbackApplied = "1";
      target.removeAttribute("srcset");
      target.src = POSTER_FALLBACK_SRC;
    },
    true,
  );
}
