const STREAMIX_CACHE_PREFIX = "streamix-";

export const parseExpectedCacheName = (source) => {
  const match = source?.match(/const CACHE_VERSION = ['"]([^'"]+)['"]/);
  return match ? `${STREAMIX_CACHE_PREFIX}${match[1]}` : null;
};

export const fetchExpectedCacheName = async () => {
  const response = await fetch(`/sw.js?ts=${Date.now()}`, {
    cache: "no-store",
    headers: { "cache-control": "no-cache" },
  });
  if (!response.ok) return null;
  return parseExpectedCacheName(await response.text());
};

export const streamixCacheNames = async () => {
  if (!("caches" in window)) return [];
  const names = await caches.keys();
  return names.filter((name) => name.startsWith(STREAMIX_CACHE_PREFIX));
};

export const clearStreamixCaches = async () => {
  const names = await streamixCacheNames();
  await Promise.all(names.map((name) => caches.delete(name)));
  return names;
};

export const repairPwaApp = async ({ reload = true } = {}) => {
  const deletedCaches = await clearStreamixCaches();
  const registration = await navigator.serviceWorker?.getRegistration("/");

  if (registration) {
    await registration.update();
    registration.waiting?.postMessage({ type: "SKIP_WAITING" });
  }

  if (reload) {
    window.setTimeout(() => window.location.reload(), 700);
  }

  return { deletedCaches, hasRegistration: Boolean(registration) };
};

const createDismissButton = () => {
  const button = document.createElement("button");
  button.type = "button";
  button.className =
    "flex min-h-11 min-w-11 shrink-0 items-center justify-center rounded-md px-2 py-1 text-sm text-text-secondary hover:text-text-primary";
  button.setAttribute("aria-label", "Fechar aviso de atualização");
  button.textContent = "Agora não";
  return button;
};

const showPwaRepairToast = ({ expectedCache, caches: currentCaches, isStandalonePwa }) => {
  if (!isStandalonePwa() || document.getElementById("pwa-repair-toast")) return;

  const toast = document.createElement("div");
  toast.id = "pwa-repair-toast";
  toast.className =
    "fixed inset-x-4 bottom-4 z-[9999] rounded-lg border border-warning/30 bg-surface/95 p-4 text-sm text-text-primary shadow-2xl backdrop-blur safe-area-bottom";

  const title = document.createElement("p");
  title.className = "font-semibold text-text-primary";
  title.textContent = "Atualização disponível";

  const copy = document.createElement("p");
  copy.className = "mt-1 text-xs leading-5 text-text-secondary";
  copy.textContent = `Seu app está usando ${currentCaches.join(", ") || "cache antigo"}; versão esperada ${expectedCache}.`;

  const actions = document.createElement("div");
  actions.className = "mt-3 flex gap-2";

  const update = document.createElement("button");
  update.type = "button";
  update.className = "min-h-11 rounded-md bg-brand px-3 py-2 text-xs font-medium text-white";
  update.textContent = "Atualizar app";
  update.addEventListener("click", async () => {
    update.disabled = true;
    update.textContent = "Atualizando...";
    await repairPwaApp();
  });

  const dismiss = createDismissButton();
  dismiss.addEventListener("click", () => toast.remove());

  actions.appendChild(update);
  actions.appendChild(dismiss);
  toast.appendChild(title);
  toast.appendChild(copy);
  toast.appendChild(actions);
  document.body.appendChild(toast);
};

export const checkPwaCacheFreshness = async (isStandalonePwa) => {
  if (!isStandalonePwa() || !("caches" in window) || !("serviceWorker" in navigator)) return;

  try {
    const [expectedCache, currentCaches] = await Promise.all([
      fetchExpectedCacheName(),
      streamixCacheNames(),
    ]);
    if (!expectedCache || currentCaches.length === 0) return;
    if (!currentCaches.includes(expectedCache) || currentCaches.length > 1) {
      showPwaRepairToast({ expectedCache, caches: currentCaches, isStandalonePwa });
    }
  } catch (_error) {}
};
