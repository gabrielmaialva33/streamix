import assert from "node:assert/strict";
import test from "node:test";

import { StreamLoader } from "../media/stream_loader.js";

const EVENTS = Object.freeze({
  FRAG_LOADED: "frag-loaded",
  MANIFEST_PARSED: "manifest-parsed",
  LEVEL_SWITCHED: "level-switched",
  AUDIO_TRACKS_UPDATED: "audio-tracks-updated",
  SUBTITLE_TRACKS_UPDATED: "subtitle-tracks-updated",
  ERROR: "error",
});

function fakeHlsClass(rawCalls) {
  return class FakeHls {
    static Events = EVENTS;

    static isSupported() {
      return true;
    }

    constructor() {
      this.handlers = new Map();
      this.levels = [];
      this.audioTracks = [];
      this.subtitleTracks = [];
      rawCalls.push(["create"]);
    }

    on(event, handler) {
      this.handlers.set(event, handler);
    }

    destroy() {
      rawCalls.push(["raw-destroy"]);
    }
  };
}

function videoDouble() {
  return {
    play() {},
    pause() {},
  };
}

test("StreamLoader owns the HLS engine lifecycle and exposes it to the hook", async () => {
  const rawCalls = [];
  const engineCalls = [];
  const Hls = fakeHlsClass(rawCalls);
  let engine;

  const loader = new StreamLoader({
    video: videoDouble(),
    getHls: async () => Hls,
    createHlsPlaybackEngine({ hls, video, resetSourceOnDestroy }) {
      engine = {
        client: hls,
        load(url) {
          engineCalls.push(["load", url, video]);
          return hls;
        },
        reload(url) {
          engineCalls.push(["reload", url]);
          return hls;
        },
        destroy() {
          engineCalls.push(["destroy", resetSourceOnDestroy]);
          return true;
        },
      };

      return engine;
    },
  });

  const rawHls = await loader.loadHls("https://example.test/one.m3u8");

  assert.equal(loader.getHls(), rawHls);
  assert.equal(loader.getHlsEngine(), engine);
  assert.deepEqual(engineCalls, [["load", "https://example.test/one.m3u8", loader.video]]);

  assert.equal(await loader.loadHlsSoft("https://example.test/two.m3u8"), rawHls);
  assert.deepEqual(engineCalls.at(-1), ["reload", "https://example.test/two.m3u8"]);

  loader.destroy();

  assert.deepEqual(engineCalls.at(-1), ["destroy", false]);
  assert.equal(loader.getHlsEngine(), null);
  assert.equal(
    rawCalls.some(([operation]) => operation === "raw-destroy"),
    false,
  );
});

test("a full HLS reload destroys the previous engine before replacing it", async () => {
  const rawCalls = [];
  const engineCalls = [];
  const Hls = fakeHlsClass(rawCalls);
  let sequence = 0;

  const loader = new StreamLoader({
    video: videoDouble(),
    getHls: async () => Hls,
    createHlsPlaybackEngine({ hls }) {
      sequence += 1;
      const id = sequence;

      return {
        client: hls,
        load(url) {
          engineCalls.push([id, "load", url]);
          return hls;
        },
        reload(url) {
          engineCalls.push([id, "reload", url]);
          return hls;
        },
        destroy() {
          engineCalls.push([id, "destroy"]);
          return true;
        },
      };
    },
  });

  await loader.loadHls("https://example.test/one.m3u8");
  await loader.loadHls("https://example.test/two.m3u8");

  assert.deepEqual(engineCalls, [
    [1, "load", "https://example.test/one.m3u8"],
    [1, "destroy"],
    [2, "load", "https://example.test/two.m3u8"],
  ]);
});
