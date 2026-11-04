import assert from "node:assert/strict";
import test from "node:test";

import {
  buildMediaDecodingConfiguration,
  configurationFromPlayerElement,
  probeMediaCapability,
  summarizeMediaCapability,
} from "../player/media_capability_policy.js";

test("builds a bounded media-source decoding configuration", () => {
  const configuration = buildMediaDecodingConfiguration({
    videoCodec: "hvc1.1.6.L120.B0",
    width: 3840,
    height: 2160,
    bitrate: 20_000_000,
    framerate: 60,
  });

  assert.equal(configuration.type, "media-source");
  assert.match(configuration.video.contentType, /hvc1\.1\.6\.L120\.B0/);
  assert.equal(configuration.video.width, 3840);
  assert.equal(configuration.video.height, 2160);
  assert.equal(configuration.video.framerate, 60);
  assert.equal(Object.isFrozen(configuration), true);
});

test("summarizes smooth and power-efficient decoding", () => {
  assert.deepEqual(
    summarizeMediaCapability({
      supported: true,
      smooth: true,
      powerEfficient: true,
    }),
    {
      available: true,
      supported: true,
      smooth: true,
      powerEfficient: true,
      preferNative: true,
      avoidNative: false,
      avoidHighResolution: false,
      configuration: null,
    },
  );

  const risky = summarizeMediaCapability({
    supported: true,
    smooth: false,
    powerEfficient: false,
  });
  assert.equal(risky.avoidNative, true);
  assert.equal(risky.avoidHighResolution, true);
});

test("probes navigator.mediaCapabilities through an injected boundary", async () => {
  const seen = [];
  const configuration = buildMediaDecodingConfiguration();
  const result = await probeMediaCapability({
    configuration,
    async decodingInfo(value) {
      seen.push(value);
      return { supported: true, smooth: true, powerEfficient: false };
    },
  });

  assert.deepEqual(seen, [configuration]);
  assert.equal(result.supported, true);
  assert.equal(result.smooth, true);
  assert.equal(result.powerEfficient, false);
  assert.equal(result.avoidHighResolution, true);
});

test("bounds a slow Media Capabilities probe", async () => {
  const startedAt = Date.now();
  const result = await probeMediaCapability({
    timeoutMs: 5,
    decodingInfo: () => new Promise(() => {}),
  });

  assert.equal(result.available, false);
  assert.ok(Date.now() - startedAt < 100);
});

test("degrades safely when Media Capabilities is unavailable or throws", async () => {
  const unavailable = await probeMediaCapability({ decodingInfo: null });
  assert.equal(unavailable.available, false);
  assert.equal(unavailable.avoidNative, false);

  const failed = await probeMediaCapability({
    decodingInfo() {
      throw new Error("not supported");
    },
  });
  assert.equal(failed.available, false);
});

test("derives codec and resolution hints from the player element", () => {
  const configuration = configurationFromPlayerElement(
    {
      dataset: {
        videoCodec: "av01.0.08M.08",
        audioCodec: "mp4a.40.2",
        width: "2560",
        height: "1440",
        bitrate: "12000000",
        framerate: "60",
      },
    },
    "mp4",
  );

  assert.match(configuration.video.contentType, /av01\.0\.08M\.08/);
  assert.equal(configuration.video.width, 2560);
  assert.equal(configuration.video.height, 1440);
  assert.equal(configuration.video.bitrate, 12_000_000);
});

test("a completed capability probe releases its deadline immediately", async (t) => {
  const pending = new Set();
  t.mock.method(globalThis, "setTimeout", () => {
    const id = {};
    pending.add(id);
    return id;
  });
  t.mock.method(globalThis, "clearTimeout", (id) => pending.delete(id));
  const result = await probeMediaCapability({ decodingInfo: async () => ({ supported: true }) });
  assert.equal(result.supported, true);
  assert.equal(pending.size, 0);
});

test("canonical capability keys cannot be overridden by obsolete aliases", () => {
  const configuration = configurationFromPlayerElement({
    dataset: {
      width: "640",
      height: "360",
      bitrate: "500000",
      framerate: "24",
      videoWidth: "3840",
      videoHeight: "2160",
      videoBitrate: "20000000",
      frameRate: "60",
      codec: "obsolete",
      audioChannels: "8",
    },
  });
  assert.equal(configuration.video.width, 640);
  assert.equal(configuration.video.height, 360);
  assert.equal(configuration.video.bitrate, 500000);
  assert.equal(configuration.video.framerate, 24);
  assert.doesNotMatch(configuration.video.contentType, /obsolete/);
  assert.equal(configuration.audio.channels, "2");
});
