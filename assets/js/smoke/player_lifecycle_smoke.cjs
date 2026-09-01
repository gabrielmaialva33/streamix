const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require("playwright");

const productionOrigin = "https://streamix.mahina.fun";
const configuredUrl = process.env.STREAMIX_SMOKE_URL;
const storageState = process.env.STREAMIX_SMOKE_STORAGE_STATE;
const email = process.env.STREAMIX_SMOKE_EMAIL;
const password = process.env.STREAMIX_SMOKE_PASSWORD;
const localAssetDir = process.env.STREAMIX_SMOKE_ASSET_DIR;
const configuredContentId = process.env.STREAMIX_SMOKE_CONTENT_ID;
const resumeTime = Number(process.env.STREAMIX_SMOKE_RESUME_TIME || 25);
const timeoutMs = Number(process.env.STREAMIX_SMOKE_TIMEOUT_MS || 20_000);
const initialVolume = 0.72;
const adjustedVolume = 0.65;

function fail(message, snapshot) {
  console.error(JSON.stringify({ ok: false, message, snapshot }, null, 2));
  process.exit(1);
}

function assertLifecycle(snapshot) {
  if (!snapshot.hasPlayer) fail("player container not found", snapshot);
  if (snapshot.videoCount !== 1) fail("expected exactly one video element", snapshot);
  if (snapshot.avPlayerChildren !== 0) fail("unexpected AVPlayer mount children", snapshot);
  if (snapshot.autoplay) fail("native video autoplay must stay disabled", snapshot);
  if (snapshot.preload !== "metadata") fail("native video preload must be metadata", snapshot);

  const seekIndex = snapshot.events.findIndex((event) => event.startsWith(`seek:${resumeTime}`));
  const playIndex = snapshot.events.findIndex((event) => event.startsWith("play:"));

  if (seekIndex !== -1 && playIndex !== -1 && seekIndex > playIndex) {
    fail("native play happened before resume seek", snapshot);
  }
}

function assertInitialAudio(snapshot) {
  if (snapshot.videoMuted !== true) fail("stored mute state was not applied to video", snapshot);
  if (snapshot.savedMuted !== true || snapshot.savedVolume !== initialVolume) {
    fail("stored audio preferences were not preserved", snapshot);
  }
  if (snapshot.sliderValue !== 0) fail("muted slider did not render at zero", snapshot);
  if (!snapshot.volumeOnHidden || snapshot.volumeOffHidden) {
    fail("muted icon state is out of sync", snapshot);
  }
  if (snapshot.muteAriaPressed !== "true") fail("mute button state is not exposed", snapshot);
}

function assertAdjustedAudio(snapshot) {
  if (snapshot.videoMuted !== false) fail("native audio state stayed muted", snapshot);
  if (snapshot.sliderValue !== adjustedVolume * 100) {
    fail("volume slider did not keep the selected value", snapshot);
  }
  if (snapshot.volumeOnHidden || !snapshot.volumeOffHidden) {
    fail("audible icon state is out of sync", snapshot);
  }
  if (snapshot.muteAriaPressed !== "false") fail("mute button still reports muted", snapshot);
  if (snapshot.savedMuted !== false || snapshot.savedVolume !== adjustedVolume) {
    fail("adjusted audio state was not persisted", snapshot);
  }
}

function contentIdFromUrl(url) {
  return new URL(url).pathname.match(/^\/watch\/[^/]+\/(\d+)$/)?.[1];
}

async function discoverProductionTarget(context) {
  const page = await context.newPage();

  try {
    await page.goto(productionOrigin, { waitUntil: "domcontentloaded", timeout: timeoutMs });
    await page.waitForFunction(() => window.liveSocket?.isConnected?.() === true, null, {
      timeout: timeoutMs,
    });

    const elementId = await page
      .locator("[id^='public-movie-img-']")
      .first()
      .getAttribute("id", { timeout: timeoutMs });
    const contentId = elementId?.match(/^public-movie-img-(\d+)$/)?.[1];

    if (!contentId) {
      throw new Error("could not discover a current public movie for the player smoke");
    }

    return {
      contentId,
      url: new URL(`/watch/movie/${contentId}`, productionOrigin).href,
    };
  } finally {
    await page.close();
  }
}

async function resolveTarget(context) {
  if (!configuredUrl) return discoverProductionTarget(context);

  const contentId = configuredContentId || contentIdFromUrl(configuredUrl);
  if (!contentId) {
    throw new Error(
      "STREAMIX_SMOKE_CONTENT_ID is required when STREAMIX_SMOKE_URL has no numeric watch id",
    );
  }

  return { contentId, url: new URL(configuredUrl).href };
}

async function main() {
  if (!storageState && !(email && password)) {
    fail("player smoke requires a storage state or email/password credentials", {});
  }

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    ...(storageState ? { storageState } : {}),
    serviceWorkers: "block",
  });
  const target = await resolveTarget(context);

  await context.addInitScript(
    ({ contentId, initialVolume, resumeTime }) => {
      window.__streamixSmoke = { events: [] };

      const positions = {};
      positions[contentId] = { time: resumeTime, duration: 7200, timestamp: Date.now() };
      localStorage.setItem("streamix_playback_positions", JSON.stringify(positions));
      localStorage.setItem(
        "streamix_player_prefs",
        JSON.stringify({ global: { muted: true, volume: initialVolume } }),
      );

      const currentTime = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "currentTime");
      if (currentTime?.set && currentTime?.get) {
        Object.defineProperty(HTMLMediaElement.prototype, "currentTime", {
          configurable: true,
          get() {
            return currentTime.get.call(this);
          },
          set(value) {
            window.__streamixSmoke.events.push(`seek:${Number(value).toFixed(3)}`);
            return currentTime.set.call(this, value);
          },
        });
      }

      const play = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function (...args) {
        window.__streamixSmoke.events.push(`play:${Number(this.currentTime || 0).toFixed(3)}`);
        return play.apply(this, args);
      };
    },
    { contentId: target.contentId, initialVolume, resumeTime },
  );

  const page = await context.newPage();

  if (!storageState && email && password) {
    await page.goto(new URL("/login", target.url).href, {
      waitUntil: "domcontentloaded",
      timeout: timeoutMs,
    });
    await page.locator('input[name="user[email]"]').fill(email);
    await page.locator('input[name="user[password]"]').fill(password);
    await page.getByRole("button", { name: "Entrar", exact: true }).click({ noWaitAfter: true });
    await page.waitForFunction(() => window.location.pathname !== "/login", null, {
      timeout: timeoutMs,
    });
  }

  if (localAssetDir) {
    const jsRoot = path.resolve(localAssetDir, "js");

    await page.route("**/assets/js/**", async (route) => {
      const marker = "/assets/js/";
      const pathname = new URL(route.request().url()).pathname;
      const relativePath = decodeURIComponent(pathname.slice(pathname.indexOf(marker) + marker.length));
      const assetPath = path.resolve(jsRoot, relativePath);

      if (assetPath.startsWith(`${jsRoot}${path.sep}`) && fs.existsSync(assetPath)) {
        await route.fulfill({
          body: fs.readFileSync(assetPath),
          contentType: "application/javascript",
        });
      } else {
        await route.continue();
      }
    });
  }

  await page.goto(target.url, { waitUntil: "domcontentloaded", timeout: timeoutMs });
  await page.waitForSelector("#video-player-container", { timeout: timeoutMs });
  await page.waitForTimeout(3_000);

  const snapshot = await page.evaluate(() => {
    const video = document.querySelector("#video-element");
    const container = document.querySelector("#video-player-container");
    const avMount = document.querySelector("#avplayer-mount");
    const prefs = JSON.parse(localStorage.getItem("streamix_player_prefs") || "{}");
    const buffered = [];

    if (video) {
      for (let i = 0; i < video.buffered.length; i++) {
        buffered.push(`${video.buffered.start(i).toFixed(2)}-${video.buffered.end(i).toFixed(2)}`);
      }
    }

    return {
      hasPlayer: !!container,
      videoCount: document.querySelectorAll("video").length,
      avPlayerChildren: avMount ? avMount.childElementCount : -1,
      autoplay: video ? video.autoplay : true,
      preload: video ? video.getAttribute("preload") : null,
      currentTime: video ? Number((video.currentTime || 0).toFixed(3)) : 0,
      readyState: video ? video.readyState : null,
      networkState: video ? video.networkState : null,
      paused: video ? video.paused : null,
      videoMuted: video?.muted,
      sliderValue: Number(document.querySelector("#volume-slider")?.value),
      volumeOnHidden: document.querySelector(".volume-on-icon")?.classList.contains("hidden"),
      volumeOffHidden: document.querySelector(".volume-off-icon")?.classList.contains("hidden"),
      muteAriaPressed: document.querySelector("#mute-btn")?.getAttribute("aria-pressed"),
      savedMuted: prefs.global?.muted,
      savedVolume: prefs.global?.volume,
      buffered,
      events: window.__streamixSmoke?.events || [],
    };
  });

  assertLifecycle(snapshot);
  assertInitialAudio(snapshot);

  await page.evaluate((volume) => {
    const slider = document.querySelector("#volume-slider");
    slider.value = String(volume * 100);
    slider.dispatchEvent(new Event("input", { bubbles: true }));
  }, adjustedVolume);
  await page.waitForTimeout(100);

  const adjustedAudio = await page.evaluate(() => {
    const video = document.querySelector("#video-element");
    const prefs = JSON.parse(localStorage.getItem("streamix_player_prefs") || "{}");

    return {
      videoMuted: video?.muted,
      sliderValue: Number(document.querySelector("#volume-slider")?.value),
      volumeOnHidden: document.querySelector(".volume-on-icon")?.classList.contains("hidden"),
      volumeOffHidden: document.querySelector(".volume-off-icon")?.classList.contains("hidden"),
      muteAriaPressed: document.querySelector("#mute-btn")?.getAttribute("aria-pressed"),
      savedMuted: prefs.global?.muted,
      savedVolume: prefs.global?.volume,
    };
  });

  assertAdjustedAudio(adjustedAudio);
  console.log(JSON.stringify({ ok: true, url: target.url, snapshot, adjustedAudio }, null, 2));

  await browser.close();
}

main().catch((error) => {
  fail(error.message, { stack: error.stack });
});
