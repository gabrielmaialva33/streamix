import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { dirname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

import { chromium, firefox, webkit } from "playwright";

const browserName = process.argv[2] || process.env.PLAYWRIGHT_BROWSER || "chromium";
const browsers = { chromium, firefox, webkit };
const browserType = browsers[browserName];

if (!browserType) {
  throw new TypeError(`Unsupported browser: ${browserName}`);
}

const assetsRoot = process.env.STREAMIX_ASSETS_ROOT
  ? normalize(process.env.STREAMIX_ASSETS_ROOT)
  : join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const allowedRoot = normalize(join(assetsRoot, "js"));

function contentType(path) {
  if (path.endsWith(".js") || path.endsWith(".mjs")) return "text/javascript; charset=utf-8";
  return "text/plain; charset=utf-8";
}

const server = createServer(async (request, response) => {
  try {
    if (request.url === "/") {
      response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      response.end("<!doctype html><video id=video></video>");
      return;
    }

    const requested = normalize(join(assetsRoot, request.url || "/"));
    if (!requested.startsWith(allowedRoot)) {
      response.writeHead(403);
      response.end("forbidden");
      return;
    }

    const body = await readFile(requested);
    response.writeHead(200, {
      "cache-control": "no-store",
      "content-type": contentType(requested),
    });
    response.end(body);
  } catch (error) {
    response.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    response.end(error instanceof Error ? error.message : "not found");
  }
});

await new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(0, "127.0.0.1", resolve);
});

const address = server.address();
if (!address || typeof address === "string") throw new Error("Browser gate server did not start");
const baseUrl = `http://127.0.0.1:${address.port}`;

let browser;
try {
  browser = await browserType.launch({ headless: true });
  const page = await browser.newPage();
  await page.goto(baseUrl, { waitUntil: "domcontentloaded" });

  const result = await page.evaluate(async (moduleUrl) => {
    const module = await import(moduleUrl);
    const factory = module.createMpegtsPlaybackEngine;
    if (typeof factory !== "function") {
      throw new TypeError("createMpegtsPlaybackEngine export is missing");
    }

    const video = document.querySelector("video");
    const calls = [];
    let playing = false;

    Object.defineProperties(video, {
      currentTime: { configurable: true, writable: true, value: 0 },
      duration: { configurable: true, value: 120 },
      ended: { configurable: true, get: () => false },
      paused: { configurable: true, get: () => !playing },
      play: {
        configurable: true,
        value: async () => {
          playing = true;
          calls.push("video.play");
        },
      },
      pause: {
        configurable: true,
        value: () => {
          playing = false;
          calls.push("video.pause");
        },
      },
    });

    const handlers = new Map();
    const client = {
      mediaInfo: { width: 1920, height: 1080, mimeType: "video/mp2t" },
      statisticsInfo: { decodedFrames: 42, droppedFrames: 2, speed: 1 },
      attachMediaElement(element) {
        if (element !== video) throw new Error("unexpected media element");
        calls.push("attach");
      },
      detachMediaElement() {
        calls.push("detach");
      },
      load() {
        calls.push("load");
      },
      unload() {
        calls.push("unload");
      },
      destroy() {
        calls.push("destroy");
      },
      play() {
        calls.push("client.play");
        return video.play();
      },
      pause() {
        calls.push("client.pause");
        video.pause();
      },
      seek(seconds) {
        calls.push("client.seek");
        video.currentTime = seconds;
        return seconds;
      },
      setVolume(volume) {
        calls.push("client.setVolume");
        video.volume = volume;
        return volume;
      },
      getCurrentTime() {
        return video.currentTime;
      },
      getDuration() {
        return video.duration;
      },
      isPlaying() {
        return playing;
      },
      getMediaInfo() {
        return this.mediaInfo;
      },
      getStatisticsInfo() {
        return this.statisticsInfo;
      },
      on(event, handler) {
        handlers.set(event, handler);
      },
      off(event, handler) {
        if (handlers.get(event) === handler) handlers.delete(event);
      },
    };

    const source = { type: "mpegts", url: "https://example.invalid/live.ts", isLive: true };
    const sharedOptions = {
      video,
      media: video,
      player: client,
      client,
      mpegtsPlayer: client,
      engine: client,
      source,
      resetSourceOnDestroy: false,
    };

    const attempts = [
      () => factory(sharedOptions),
      () => factory({ video, player: client, source, resetSourceOnDestroy: false }),
      () => factory({ video, client, source, resetSourceOnDestroy: false }),
      () => factory({ video, mpegtsPlayer: client, source, resetSourceOnDestroy: false }),
      () => factory({ video, engine: client, source, resetSourceOnDestroy: false }),
      () => factory(video, client, { source, resetSourceOnDestroy: false }),
    ];

    let engine;
    let lastError;
    for (const attempt of attempts) {
      try {
        engine = attempt();
        break;
      } catch (error) {
        lastError = error;
      }
    }
    if (!engine) throw lastError || new Error("MPEG-TS engine could not be constructed");

    const requiredMethods = ["load", "play", "pause", "seek", "snapshot", "destroy"];
    for (const method of requiredMethods) {
      if (typeof engine[method] !== "function") throw new TypeError(`missing ${method}()`);
    }

    await engine.load(source);
    await engine.play();
    engine.seek(18.5);
    engine.pause();
    const snapshot = engine.snapshot();
    const firstDestroy = engine.destroy();
    const secondDestroy = engine.destroy();
    await Promise.allSettled([firstDestroy, secondDestroy]);

    return {
      calls,
      currentTime: video.currentTime,
      snapshot,
      destroyedCalls: calls.filter((call) => call === "destroy").length,
    };
  }, `${baseUrl}/js/player/mpegts_playback_engine.js`);

  assert.equal(result.currentTime, 18.5);
  assert.equal(result.snapshot.engine, "mpegts");
  assert.equal(result.snapshot.live ?? result.snapshot.isLive, true);
  assert.equal(result.destroyedCalls, 1);
  assert.ok(result.calls.indexOf("attach") < result.calls.indexOf("load"));
  assert.ok(result.calls.includes("unload"));
  assert.ok(result.calls.includes("detach"));

  console.log(`MPEG-TS browser gate passed: ${browserName}`);
} finally {
  await browser?.close();
  await new Promise((resolve) => server.close(resolve));
}
