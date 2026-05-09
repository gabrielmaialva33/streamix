const STORAGE_KEYS = [
  "streamix:pwa-last-route",
  "streamix:ios-player-state",
  "streamix:pwa-install-hint-dismissed",
  "streamix_playback_positions",
  "streamix_player_prefs",
  "streamix_device_compat",
];

function safeJsonParse(value, fallback = null) {
  try {
    return JSON.parse(value);
  } catch (_error) {
    return fallback;
  }
}

function readStorageSnapshot() {
  const result = {
    localStorage: { available: false, keys: {} },
    sessionStorage: { available: false, keyCount: 0 },
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

const PwaDebug = {
  mounted() {
    this.output = document.getElementById("pwa-debug-output");
    this.status = document.getElementById("pwa-debug-status");
    this.refreshButton = document.getElementById("pwa-debug-refresh");
    this.downloadButton = document.getElementById("pwa-debug-download");
    this.serverDebug = safeJsonParse(this.el.dataset.serverDebug, {});
    this.latestText = "";

    this.refresh = this.refresh.bind(this);
    this.download = this.download.bind(this);

    this.refreshButton?.addEventListener("click", this.refresh);
    this.downloadButton?.addEventListener("click", this.download);

    this.refresh();
  },

  destroyed() {
    this.refreshButton?.removeEventListener("click", this.refresh);
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

    this.latestText = [
      "Streamix PWA Debug",
      `Generated at: ${snapshot.browser.generatedAt}`,
      "",
      JSON.stringify(snapshot, null, 2),
      "",
    ].join("\n");

    if (this.output) {
      this.output.textContent = this.latestText;
    }

    this.setStatus("Atualizado agora");
  },

  download() {
    if (!this.latestText) {
      this.refresh();
      return;
    }

    const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
    const blob = new Blob([this.latestText], { type: "text/plain;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");

    anchor.href = url;
    anchor.download = `streamix-pwa-debug-${timestamp}.txt`;
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
    URL.revokeObjectURL(url);
  },

  setStatus(message) {
    if (this.status) {
      this.status.textContent = message;
    }
  },
};

export default PwaDebug;
