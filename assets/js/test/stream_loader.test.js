import assert from "node:assert/strict";
import test from "node:test";

import { isStreamLoaderCancelledError, StreamLoader } from "../media/stream_loader.js";

const HLS_EVENTS = {
  FRAG_LOADED: "frag",
  MANIFEST_PARSED: "manifest",
  LEVEL_SWITCHED: "level",
  AUDIO_TRACKS_UPDATED: "audio",
  SUBTITLE_TRACKS_UPDATED: "subtitle",
  ERROR: "error",
};

const MPEGTS_EVENTS = {
  STATISTICS_INFO: "statistics",
  MEDIA_INFO: "media",
  ERROR: "error",
};

const deferred = () => {
  let resolve;
  const promise = new Promise((done) => {
    resolve = done;
  });
  return { promise, resolve };
};

function createFakeHls(calls = []) {
  return class FakeHls {
    static Events = HLS_EVENTS;

    static isSupported() {
      return true;
    }

    constructor() {
      calls.push("create");
      this.handlers = new Map();
      this.levels = [{ height: 720 }];
      this.audioTracks = [];
      this.subtitleTracks = [];
      this.targetLatency = 0;
    }

    on(event, callback) {
      calls.push(`on:${event}`);
      this.handlers.set(event, callback);
    }

    loadSource() {
      calls.push("loadSource");
      assert.equal(this.handlers.size, Object.keys(HLS_EVENTS).length);
      this.handlers.get(HLS_EVENTS.MANIFEST_PARSED)?.("manifest", { levels: this.levels });
      this.handlers.get(HLS_EVENTS.ERROR)?.("error", { fatal: true, type: "networkError" });
    }

    attachMedia() {
      calls.push("attachMedia");
      assert.equal(this.handlers.size, Object.keys(HLS_EVENTS).length);
    }

    destroy() {
      calls.push("destroy");
    }
  };
}

function createFakeMpegts(calls = []) {
  return {
    Events: MPEGTS_EVENTS,
    createPlayer() {
      calls.push("create");
      const handlers = new Map();
      return {
        on(event, callback) {
          calls.push(`on:${event}`);
          handlers.set(event, callback);
        },
        attachMediaElement() {
          calls.push("attach");
          assert.equal(handlers.size, Object.keys(MPEGTS_EVENTS).length);
          handlers.get(MPEGTS_EVENTS.MEDIA_INFO)?.({ codec: "h264" });
          handlers.get(MPEGTS_EVENTS.ERROR)?.("NetworkError", "NetworkTimeout", { code: 504 });
        },
        load() {
          calls.push("load");
          assert.equal(handlers.size, Object.keys(MPEGTS_EVENTS).length);
        },
        pause() {
          calls.push("pause");
        },
        unload() {
          calls.push("unload");
        },
        detachMediaElement() {
          calls.push("detach");
        },
        destroy() {
          calls.push("destroy");
        },
      };
    },
  };
}

test("HLS listeners observe synchronous events emitted by loadSource", async () => {
  const calls = [];
  const manifests = [];
  const errors = [];
  const Hls = createFakeHls(calls);
  const loader = new StreamLoader({
    video: {},
    getHls: async () => Hls,
    onManifestParsed: (data, sessionId) => manifests.push({ data, sessionId }),
    onError: (type, data, sessionId) => errors.push({ data, sessionId, type }),
    sessionId: 7,
  });

  await loader.loadHls("https://example.test/live.m3u8");

  assert.equal(manifests.length, 1);
  assert.equal(manifests[0].sessionId, 7);
  assert.equal(errors.length, 1);
  assert.equal(errors[0].type, "hls");
  assert.ok(calls.lastIndexOf("on:error") < calls.indexOf("loadSource"));
  assert.ok(calls.indexOf("loadSource") < calls.indexOf("attachMedia"));
});

test("mpegts listeners observe synchronous events emitted by attach/load", async () => {
  const calls = [];
  const mediaInfo = [];
  const errors = [];
  const mpegts = createFakeMpegts(calls);
  const loader = new StreamLoader({
    video: {},
    getMpegts: async () => mpegts,
    onMediaInfo: (info, sessionId) => mediaInfo.push({ info, sessionId }),
    onError: (type, data, sessionId) => errors.push({ data, sessionId, type }),
    sessionId: 11,
  });

  await loader.loadMpegts("https://example.test/live.ts");

  assert.deepEqual(mediaInfo, [{ info: { codec: "h264" }, sessionId: 11 }]);
  assert.equal(errors.length, 1);
  assert.equal(errors[0].data.errorDetail, "NetworkTimeout");
  assert.ok(calls.lastIndexOf("on:error") < calls.indexOf("attach"));
  assert.ok(calls.indexOf("attach") < calls.indexOf("load"));
});

test("destroy cancels a pending HLS lazy load before an engine is created", async () => {
  const importGate = deferred();
  const calls = [];
  const Hls = createFakeHls(calls);
  const loader = new StreamLoader({ video: {}, getHls: () => importGate.promise });
  const loading = loader.loadHls("https://example.test/live.m3u8");

  loader.destroy();
  importGate.resolve(Hls);

  await assert.rejects(loading, isStreamLoaderCancelledError);
  assert.equal(calls.includes("create"), false);
  assert.equal(loader.getHls(), null);
});

test("a stale mpegts import cannot attach or overwrite a newer loader session", async () => {
  const importGate = deferred();
  const oldCalls = [];
  const newCalls = [];
  const oldMpegts = createFakeMpegts(oldCalls);
  const newMpegts = createFakeMpegts(newCalls);
  const oldLoader = new StreamLoader({ video: {}, getMpegts: () => importGate.promise });
  const oldLoading = oldLoader.loadMpegts("https://example.test/old.ts");

  oldLoader.destroy();
  const newLoader = new StreamLoader({ video: {}, getMpegts: async () => newMpegts });
  const currentPlayer = await newLoader.loadMpegts("https://example.test/new.ts");
  importGate.resolve(oldMpegts);

  await assert.rejects(oldLoading, isStreamLoaderCancelledError);
  assert.equal(oldCalls.includes("create"), false);
  assert.equal(oldLoader.getMpegtsPlayer(), null);
  assert.equal(newLoader.getMpegtsPlayer(), currentPlayer);
  assert.equal(newCalls.filter((call) => call === "create").length, 1);
});
