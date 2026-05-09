const { chromium } = require("playwright");

const url = process.env.STREAMIX_SMOKE_URL || "https://streamix.mahina.cloud/watch/movie/33781";
const storageState = process.env.STREAMIX_SMOKE_STORAGE_STATE;
const contentId = process.env.STREAMIX_SMOKE_CONTENT_ID || "33781";
const resumeTime = Number(process.env.STREAMIX_SMOKE_RESUME_TIME || 25);
const timeoutMs = Number(process.env.STREAMIX_SMOKE_TIMEOUT_MS || 20_000);

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

async function main() {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext(storageState ? { storageState } : {});

  await context.addInitScript(
    ({ contentId, resumeTime }) => {
      window.__streamixSmoke = { events: [] };

      const positions = {};
      positions[contentId] = { time: resumeTime, duration: 7200, timestamp: Date.now() };
      localStorage.setItem("streamix_playback_positions", JSON.stringify(positions));

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
    { contentId, resumeTime },
  );

  const page = await context.newPage();
  await page.goto(url, { waitUntil: "domcontentloaded", timeout: timeoutMs });
  await page.waitForSelector("#video-player-container", { timeout: timeoutMs });
  await page.waitForTimeout(3_000);

  const snapshot = await page.evaluate(() => {
    const video = document.querySelector("#video-element");
    const container = document.querySelector("#video-player-container");
    const avMount = document.querySelector("#avplayer-mount");
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
      buffered,
      events: window.__streamixSmoke?.events || [],
    };
  });

  assertLifecycle(snapshot);
  console.log(JSON.stringify({ ok: true, url, snapshot }, null, 2));

  await browser.close();
}

main().catch((error) => {
  fail(error.message, { stack: error.stack });
});
