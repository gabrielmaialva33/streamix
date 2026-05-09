const STORAGE_KEYS = [
  "streamix:pwa-last-route",
  "streamix:ios-player-state",
  "streamix:pwa-install-hint-dismissed",
  "streamix_playback_positions",
  "streamix_player_prefs",
  "streamix_device_compat",
];

const STREAMIX_CACHE_PREFIX = "streamix-";

function safeJsonParse(value, fallback = null) {
  try {
    return JSON.parse(value);
  } catch (_error) {
    return fallback;
  }
}

function safeText(value) {
  return value == null ? "" : String(value);
}

function createNode(tag, className, text = null) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function toneClasses(tone) {
  switch (tone) {
    case "ok":
      return "border-success/25 bg-success/10 text-success";
    case "warn":
      return "border-warning/25 bg-warning/10 text-warning";
    case "error":
      return "border-error/25 bg-error/10 text-error";
    default:
      return "border-border bg-background text-text-secondary";
  }
}

function readStorageSnapshot() {
  const result = {
    localStorage: { available: false, keys: {} },
    sessionStorage: { available: false, keyCount: 0, keys: [] },
  };

  try {
    result.localStorage.available = true;
    result.localStorage.keyCount = window.localStorage.length;

    for (const key of STORAGE_KEYS) {
      const value = window.localStorage.getItem(key);
      result.localStorage.keys[key] = value
        ? {
            present: true,
            bytes: value.length,
            parsed: safeJsonParse(value),
          }
        : { present: false };
    }
  } catch (error) {
    result.localStorage.error = error.message;
  }

  try {
    result.sessionStorage.available = true;
    result.sessionStorage.keyCount = window.sessionStorage.length;
    result.sessionStorage.keys = Array.from(
      { length: window.sessionStorage.length },
      (_, index) => {
        const key = window.sessionStorage.key(index);
        const value = key ? window.sessionStorage.getItem(key) : null;
        return {
          key,
          bytes: value?.length || 0,
        };
      },
    ).filter((entry) => entry.key);
  } catch (error) {
    result.sessionStorage.error = error.message;
  }

  return result;
}

async function readServiceWorkerSnapshot() {
  const result = {
    supported: "serviceWorker" in navigator,
    controller: Boolean(navigator.serviceWorker?.controller),
  };

  if (!result.supported) return result;

  try {
    const registration = await navigator.serviceWorker.getRegistration("/");

    result.registration = registration
      ? {
          scope: registration.scope,
          active: registration.active
            ? { state: registration.active.state, scriptURL: registration.active.scriptURL }
            : null,
          waiting: registration.waiting
            ? { state: registration.waiting.state, scriptURL: registration.waiting.scriptURL }
            : null,
          installing: registration.installing
            ? {
                state: registration.installing.state,
                scriptURL: registration.installing.scriptURL,
              }
            : null,
        }
      : null;
  } catch (error) {
    result.error = error.message;
  }

  return result;
}

async function readCacheSnapshot() {
  const result = { supported: "caches" in window, caches: [] };
  if (!result.supported) return result;

  try {
    const names = await caches.keys();
    result.caches = await Promise.all(
      names.map(async (name) => {
        const cache = await caches.open(name);
        const keys = await cache.keys();
        return {
          name,
          entries: keys.length,
          sample: keys.slice(0, 12).map((request) => request.url),
        };
      }),
    );
  } catch (error) {
    result.error = error.message;
  }

  return result;
}

async function readStorageEstimate() {
  if (!navigator.storage?.estimate) {
    return { supported: false };
  }

  try {
    const estimate = await navigator.storage.estimate();
    return { supported: true, ...estimate };
  } catch (error) {
    return { supported: true, error: error.message };
  }
}

function readMediaSnapshot() {
  const video = document.createElement("video");

  return {
    mediaSession: "mediaSession" in navigator,
    airPlay: "WebKitPlaybackTargetAvailabilityEvent" in window,
    pictureInPicture: "pictureInPictureEnabled" in document,
    canPlayType: {
      hls: video.canPlayType("application/vnd.apple.mpegurl"),
      mp4H264: video.canPlayType('video/mp4; codecs="avc1.42E01E, mp4a.40.2"'),
      hevc: video.canPlayType('video/mp4; codecs="hvc1.1.6.L93.B0"'),
      matroska: video.canPlayType("video/x-matroska"),
    },
  };
}

function readBrowserSnapshot() {
  const displayModes = ["standalone", "fullscreen", "minimal-ui", "browser"];

  return {
    generatedAt: new Date().toISOString(),
    location: window.location.href,
    userAgent: navigator.userAgent,
    platform: navigator.platform,
    vendor: navigator.vendor,
    language: navigator.language,
    languages: navigator.languages,
    cookieEnabled: navigator.cookieEnabled,
    onLine: navigator.onLine,
    standaloneNavigator: navigator.standalone === true,
    displayMode: displayModes.find((mode) => window.matchMedia(`(display-mode: ${mode})`).matches),
    touchPoints: navigator.maxTouchPoints,
    deviceMemory: navigator.deviceMemory,
    hardwareConcurrency: navigator.hardwareConcurrency,
    screen: {
      width: window.screen.width,
      height: window.screen.height,
      availWidth: window.screen.availWidth,
      availHeight: window.screen.availHeight,
      colorDepth: window.screen.colorDepth,
      devicePixelRatio: window.devicePixelRatio,
    },
    viewport: {
      width: window.innerWidth,
      height: window.innerHeight,
      visualWidth: window.visualViewport?.width,
      visualHeight: window.visualViewport?.height,
      visualScale: window.visualViewport?.scale,
    },
  };
}

function parseIosVersion(userAgent) {
  const match = safeText(userAgent).match(/OS (\d+)[_.](\d+)(?:[_.](\d+))?/);
  if (!match) return null;
  return [match[1], match[2], match[3]].filter(Boolean).join(".");
}

function buildSummary(snapshot) {
  const cacheNames = snapshot.cacheStorage.caches.map((cache) => cache.name);
  const streamixCaches = cacheNames.filter((name) => name.startsWith(STREAMIX_CACHE_PREFIX));
  const expectedCache = snapshot.server.sw_cache_name;
  const staleCache =
    expectedCache && streamixCaches.length > 0 && !streamixCaches.includes(expectedCache);
  const pwaInstalled =
    snapshot.browser.standaloneNavigator === true || snapshot.browser.displayMode === "standalone";
  const isIos = /iPhone|iPad|iPod/.test(snapshot.browser.userAgent);
  const iosVersion = parseIosVersion(snapshot.browser.userAgent);
  const hasPlayerState =
    snapshot.storage.keys.localStorage.keys["streamix:ios-player-state"]?.present;
  const hasProgress = snapshot.storage.keys.localStorage.keys.streamix_playback_positions?.present;

  const cards = [
    {
      label: "Modo",
      value: pwaInstalled ? "PWA instalado" : "Safari normal",
      tone: pwaInstalled ? "ok" : "warn",
    },
    {
      label: "iOS",
      value: isIos ? `iOS ${iosVersion || "detectado"}` : "Nao iOS",
      tone: isIos ? "ok" : "info",
    },
    {
      label: "Service Worker",
      value: snapshot.serviceWorker.controller ? "Ativo" : "Sem controle",
      tone: snapshot.serviceWorker.controller ? "ok" : "warn",
    },
    {
      label: "Cache",
      value: streamixCaches.length ? streamixCaches.join(", ") : "Sem cache Streamix",
      tone: staleCache ? "warn" : "ok",
    },
    {
      label: "Cache esperado",
      value: expectedCache || "Nao informado",
      tone: staleCache ? "warn" : "info",
    },
    {
      label: "Playback",
      value: hasPlayerState
        ? "Estado iOS salvo"
        : hasProgress
          ? "Progresso salvo"
          : "Sem estado salvo",
      tone: hasPlayerState || hasProgress ? "ok" : "info",
    },
    {
      label: "HEVC",
      value: snapshot.media.canPlayType.hevc || "nao suportado",
      tone: snapshot.media.canPlayType.hevc ? "ok" : "warn",
    },
    {
      label: "MKV nativo",
      value: snapshot.media.canPlayType.matroska || "nao suportado",
      tone: snapshot.media.canPlayType.matroska ? "ok" : "info",
    },
  ];

  const verdicts = [];
  const actions = [];

  verdicts.push({
    tone: pwaInstalled ? "ok" : "warn",
    code: pwaInstalled ? "PWA_INSTALLED" : "OPEN_FROM_HOME_SCREEN",
    text: pwaInstalled
      ? "A pagina foi aberta pelo PWA instalado."
      : "Este diagnostico foi aberto no Safari normal; abra pelo icone da Tela de Inicio para testar o PWA.",
  });

  verdicts.push({
    tone: snapshot.serviceWorker.controller ? "ok" : "warn",
    code: snapshot.serviceWorker.controller ? "SW_CONTROLLED" : "SW_NOT_CONTROLLING",
    text: snapshot.serviceWorker.controller
      ? "Service Worker ativo e controlando a pagina."
      : "Service Worker nao esta controlando a pagina; atualizar o app deve recarregar o registro.",
  });

  if (staleCache) {
    verdicts.push({
      tone: "warn",
      code: "STALE_CACHE",
      text: `Cache atual (${streamixCaches.join(", ")}) diferente do esperado (${expectedCache}).`,
    });
    actions.push(
      "Toque em Atualizar app para limpar caches antigos, procurar novo SW e recarregar.",
    );
  }

  if (snapshot.media.canPlayType.hevc) {
    verdicts.push({
      tone: "ok",
      code: "IOS_HEVC_NATIVE",
      text: "Safari iOS reporta suporte nativo a HEVC.",
    });
  }

  if (!snapshot.media.canPlayType.matroska) {
    verdicts.push({
      tone: "info",
      code: "IOS_MKV_NATIVE_UNSUPPORTED",
      text: "Safari iOS nao toca MKV nativamente; GIndex MKV precisa de AVPlayer, transcode ou remux.",
    });
  }

  if (!hasPlayerState && pwaInstalled) {
    actions.push(
      "Depois de assistir/pausar no PWA, abra este debug de novo para validar streamix:ios-player-state.",
    );
  }

  return { cards, verdicts, actions };
}

function renderSummary(container, summary) {
  if (!container) return;

  const cardsGrid = createNode("div", "grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4");

  for (const card of summary.cards) {
    const item = createNode("div", `rounded-md border p-3 ${toneClasses(card.tone)}`);
    item.appendChild(
      createNode("p", "text-xs font-medium uppercase tracking-wide opacity-80", card.label),
    );
    item.appendChild(createNode("p", "mt-1 text-sm font-semibold", card.value));
    cardsGrid.appendChild(item);
  }

  const verdictList = createNode("div", "space-y-2");
  verdictList.appendChild(createNode("h3", "text-sm font-semibold text-text-primary", "Vereditos"));

  for (const verdict of summary.verdicts) {
    const item = createNode(
      "div",
      `rounded-md border px-3 py-2 text-sm ${toneClasses(verdict.tone)}`,
    );
    item.appendChild(createNode("span", "font-mono text-xs opacity-80", verdict.code));
    item.appendChild(createNode("p", "mt-1", verdict.text));
    verdictList.appendChild(item);
  }

  const actionsList = createNode("div", "space-y-2");
  actionsList.appendChild(
    createNode("h3", "text-sm font-semibold text-text-primary", "Proximas acoes"),
  );

  if (summary.actions.length === 0) {
    actionsList.appendChild(
      createNode(
        "p",
        "rounded-md border border-border bg-background px-3 py-2 text-sm text-text-secondary",
        "Nada urgente neste snapshot.",
      ),
    );
  } else {
    for (const action of summary.actions) {
      actionsList.appendChild(
        createNode(
          "p",
          "rounded-md border border-warning/25 bg-warning/10 px-3 py-2 text-sm text-warning",
          action,
        ),
      );
    }
  }

  container.replaceChildren(cardsGrid, verdictList, actionsList);
}

function buildReportText(snapshot, summary) {
  return [
    "Streamix PWA Debug",
    `Generated at: ${snapshot.browser.generatedAt}`,
    "",
    "Summary",
    ...summary.cards.map((card) => `- ${card.label}: ${card.value}`),
    "",
    "Verdicts",
    ...summary.verdicts.map((verdict) => `- ${verdict.code}: ${verdict.text}`),
    "",
    "Actions",
    ...(summary.actions.length
      ? summary.actions.map((action) => `- ${action}`)
      : ["- Nada urgente neste snapshot."]),
    "",
    "Raw JSON",
    JSON.stringify(snapshot, null, 2),
    "",
  ].join("\n");
}

async function deleteStreamixCaches() {
  if (!("caches" in window)) return [];

  const names = await caches.keys();
  const targets = names.filter((name) => name.startsWith(STREAMIX_CACHE_PREFIX));
  await Promise.all(targets.map((name) => caches.delete(name)));
  return targets;
}

const PwaDebug = {
  mounted() {
    this.output = document.getElementById("pwa-debug-output");
    this.summary = document.getElementById("pwa-debug-summary");
    this.status = document.getElementById("pwa-debug-status");
    this.refreshButton = document.getElementById("pwa-debug-refresh");
    this.updateAppButton = document.getElementById("pwa-debug-update-app");
    this.clearCacheButton = document.getElementById("pwa-debug-clear-cache");
    this.copyButton = document.getElementById("pwa-debug-copy");
    this.shareButton = document.getElementById("pwa-debug-share");
    this.downloadButton = document.getElementById("pwa-debug-download");
    this.serverDebug = safeJsonParse(this.el.dataset.serverDebug, {});
    this.latestText = "";
    this.latestSnapshot = null;
    this.latestSummary = null;

    this.refresh = this.refresh.bind(this);
    this.updateApp = this.updateApp.bind(this);
    this.clearCache = this.clearCache.bind(this);
    this.copy = this.copy.bind(this);
    this.share = this.share.bind(this);
    this.download = this.download.bind(this);

    this.refreshButton?.addEventListener("click", this.refresh);
    this.updateAppButton?.addEventListener("click", this.updateApp);
    this.clearCacheButton?.addEventListener("click", this.clearCache);
    this.copyButton?.addEventListener("click", this.copy);
    this.shareButton?.addEventListener("click", this.share);
    this.downloadButton?.addEventListener("click", this.download);

    this.refresh();
  },

  destroyed() {
    this.refreshButton?.removeEventListener("click", this.refresh);
    this.updateAppButton?.removeEventListener("click", this.updateApp);
    this.clearCacheButton?.removeEventListener("click", this.clearCache);
    this.copyButton?.removeEventListener("click", this.copy);
    this.shareButton?.removeEventListener("click", this.share);
    this.downloadButton?.removeEventListener("click", this.download);
  },

  async refresh() {
    this.setStatus("Coletando...");

    const snapshot = {
      server: this.serverDebug,
      browser: readBrowserSnapshot(),
      media: readMediaSnapshot(),
      storage: {
        keys: readStorageSnapshot(),
        estimate: await readStorageEstimate(),
      },
      serviceWorker: await readServiceWorkerSnapshot(),
      cacheStorage: await readCacheSnapshot(),
    };

    const summary = buildSummary(snapshot);

    this.latestSnapshot = snapshot;
    this.latestSummary = summary;
    this.latestText = buildReportText(snapshot, summary);

    renderSummary(this.summary, summary);

    if (this.output) {
      this.output.textContent = this.latestText;
    }

    this.setStatus("Atualizado agora");
  },

  async updateApp() {
    this.setStatus("Atualizando app...");

    try {
      const deleted = await deleteStreamixCaches();
      const registration = await navigator.serviceWorker?.getRegistration("/");

      if (registration) {
        await registration.update();
        registration.waiting?.postMessage({ type: "SKIP_WAITING" });
      }

      this.setStatus(`Cache limpo (${deleted.length}); recarregando...`);
      window.setTimeout(() => window.location.reload(), 700);
    } catch (error) {
      this.setStatus(`Falha ao atualizar: ${error.message}`);
    }
  },

  async clearCache() {
    this.setStatus("Limpando cache...");

    try {
      const deleted = await deleteStreamixCaches();
      this.setStatus(`Cache limpo: ${deleted.length} entrada(s)`);
      await this.refresh();
    } catch (error) {
      this.setStatus(`Falha ao limpar cache: ${error.message}`);
    }
  },

  async copy() {
    if (!this.latestText) await this.refresh();

    try {
      await navigator.clipboard.writeText(this.latestText);
      this.setStatus("Diagnostico copiado");
    } catch (error) {
      this.setStatus(`Falha ao copiar: ${error.message}`);
    }
  },

  async share() {
    if (!this.latestText) await this.refresh();

    if (!navigator.share) {
      await this.copy();
      this.setStatus("Compartilhamento indisponivel; diagnostico copiado");
      return;
    }

    const filename = this.filename();
    const file = new File([this.latestText], filename, { type: "text/plain" });

    try {
      if (navigator.canShare?.({ files: [file] })) {
        await navigator.share({
          title: "Streamix PWA Debug",
          text: "Diagnostico PWA Streamix",
          files: [file],
        });
      } else {
        await navigator.share({
          title: "Streamix PWA Debug",
          text: this.latestText,
        });
      }
      this.setStatus("Diagnostico compartilhado");
    } catch (error) {
      if (error.name !== "AbortError") {
        this.setStatus(`Falha ao compartilhar: ${error.message}`);
      }
    }
  },

  async download() {
    if (!this.latestText) await this.refresh();

    const blob = new Blob([this.latestText], { type: "text/plain;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");

    anchor.href = url;
    anchor.download = this.filename();
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
    URL.revokeObjectURL(url);
  },

  filename() {
    const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
    return `streamix-pwa-debug-${timestamp}.txt`;
  },

  setStatus(message) {
    if (this.status) {
      this.status.textContent = message;
    }
  },
};

export default PwaDebug;
