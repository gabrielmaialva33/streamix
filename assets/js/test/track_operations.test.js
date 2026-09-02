import assert from "node:assert/strict";
import test from "node:test";

import {
  createTrackOperations,
  EXTERNAL_SUBTITLE_LABEL,
  TRACK_OPERATIONS_HOST_METHODS,
} from "../player/track_operations.js";

const silentLogger = { debug() {}, error() {}, info() {}, warn() {} };

function createHarness({ state: stateOverrides = {}, orchestrator, native, resolver } = {}) {
  const calls = {
    presentation: [],
    audioSelections: [],
    subtitleSelections: [],
    subtitleRefreshes: 0,
    transport: [],
  };
  const state = {
    sessionId: 3,
    avPlayer: true,
    imdbId: "tt0111161",
    preferredAudioTrack: 1,
    preferredSubtitleTrack: 0,
    selectedSubtitleTrack: 2,
    sourceType: "torrent",
    subtitleLang: "pt-BR",
    subtitleOffsetMs: 250,
    subtitleTracks: [],
    subtitlesEnabled: true,
    ...stateOverrides,
  };
  const presentation = new Proxy(
    {},
    {
      get:
        (_target, method) =>
        (...args) => {
          calls.presentation.push([method, ...args]);
          const override = state.presentation?.[method];
          return typeof override === "function" ? override(...args) : (args[0] ?? true);
        },
    },
  );
  const host = {
    getNativeSubtitleController: () => native ?? null,
    getOrchestrator: () => orchestrator ?? null,
    getPresentation: () => presentation,
    getSessionId: () => state.sessionId,
    getStreamTransport: () => ({
      setAudioTrack: (index) => calls.transport.push(["audio", index]) && "transport-audio",
      setSubtitleTrack: (index) =>
        calls.transport.push(["subtitle", index]) && "transport-subtitle",
    }),
    getSubtitleSourceResolver: () => resolver ?? null,
    getTrackState: () => ({
      imdbId: state.imdbId,
      preferredAudioTrack: state.preferredAudioTrack,
      preferredSubtitleTrack: state.preferredSubtitleTrack,
      selectedSubtitleTrack: state.selectedSubtitleTrack,
      sourceType: state.sourceType,
      subtitleLang: state.subtitleLang,
      subtitleOffsetMs: state.subtitleOffsetMs,
      subtitleTracks: state.subtitleTracks,
      subtitlesEnabled: state.subtitlesEnabled,
    }),
    hasActiveAVPlayer: () => state.avPlayer,
    isSessionCurrent: (sessionId) => sessionId === state.sessionId,
    setAudioTrack: (index) => calls.audioSelections.push(index),
    setSubtitleTrack: (index) => calls.subtitleSelections.push(index),
    updateSubtitleTracks: () => {
      calls.subtitleRefreshes += 1;
      return Promise.resolve([]);
    },
  };
  const operations = createTrackOperations({ host, logger: silentLogger });

  return { calls, host, operations, state };
}

function presented(calls, method) {
  return calls.presentation.filter(([name]) => name === method);
}

function createLease(source) {
  const lease = { source, released: 0, release: () => (lease.released += 1) };
  return lease;
}

test("the host contract is validated up front", () => {
  assert.throws(() => createTrackOperations({ host: null }), /requires an activation host/);
  const { host } = createHarness();
  for (const method of TRACK_OPERATIONS_HOST_METHODS) {
    assert.throws(
      () => createTrackOperations({ host: { ...host, [method]: undefined } }),
      new RegExp(`missing: ${method}`),
    );
  }
});

test("selectAudioTrack applies through the orchestrator and presents the selection", async () => {
  const orchestrator = { selectAudioTrack: async (index) => index };
  const { calls, operations } = createHarness({ orchestrator });

  assert.equal(await operations.selectAudioTrack(1), 1);
  assert.deepEqual(presented(calls, "presentAudioSelection"), [
    ["presentAudioSelection", 1, { sessionId: 3 }],
  ]);
  assert.deepEqual(calls.transport, []);
});

test("selectAudioTrack falls back to the stream transport without an orchestrator", async () => {
  const { calls, operations } = createHarness();

  assert.equal(await operations.selectAudioTrack(2), "transport-audio");
  assert.deepEqual(calls.transport, [["audio", 2]]);
  assert.equal(presented(calls, "presentAudioSelection").length, 1);
});

test("selectAudioTrack drops results from a superseded session", async () => {
  const harness = createHarness({
    orchestrator: {
      selectAudioTrack: async (index) => {
        harness.state.sessionId = 4;
        return index;
      },
    },
  });

  assert.equal(await harness.operations.selectAudioTrack(1), false);
  assert.equal(presented(harness.calls, "presentAudioSelection").length, 0);
});

test("selectAudioTrack reports presentation rejections", async () => {
  const { operations, state } = createHarness({
    orchestrator: { selectAudioTrack: async () => true },
  });
  state.presentation = { presentAudioSelection: () => false };

  assert.equal(await operations.selectAudioTrack(1), false);
});

test("selectSubtitleTrack prefers the native controller result and reapplies the offset", async () => {
  const delays = [];
  const orchestrator = {
    selectSubtitleTrack: async () => true,
    setSubtitleDelay: async (ms) => delays.push(ms),
  };
  const native = { select: () => "native" };
  const { calls, operations } = createHarness({ orchestrator, native });

  assert.equal(await operations.selectSubtitleTrack(0), "native");
  assert.deepEqual(presented(calls, "presentSubtitleSelection"), [
    ["presentSubtitleSelection", 0, { sessionId: 3 }],
  ]);
  assert.deepEqual(delays, [250]);
});

test("selectSubtitleTrack fails when neither the engine nor native subtitles accept it", async () => {
  const orchestrator = { selectSubtitleTrack: async () => false, setSubtitleDelay: async () => {} };
  const native = { select: () => false };
  const { calls, operations } = createHarness({ orchestrator, native });

  assert.equal(await operations.selectSubtitleTrack(5), false);
  assert.equal(presented(calls, "presentSubtitleSelection").length, 0);
});

test("setSubtitleOffset returns the engine result when the engine applies the delay", async () => {
  const scheduled = [];
  const orchestrator = { setSubtitleDelay: async () => true };
  const native = { scheduleReload: (...args) => scheduled.push(args) };
  const { calls, operations, state } = createHarness({ orchestrator, native });
  state.presentation = { presentSubtitleOffset: () => 500 };

  assert.equal(await operations.setSubtitleOffset(512), true);
  assert.deepEqual(presented(calls, "presentSubtitleOffset"), [
    ["presentSubtitleOffset", 512, { sessionId: 3 }],
  ]);
  assert.deepEqual(scheduled, []);
});

test("setSubtitleOffset schedules a native reload when the engine cannot apply the delay", async () => {
  const scheduled = [];
  const native = {
    scheduleReload: (options, onComplete) => {
      scheduled.push({ options, onComplete });
      return true;
    },
  };
  const { calls, operations, state } = createHarness({ native });
  state.presentation = { presentSubtitleOffset: () => 500 };

  assert.equal(await operations.setSubtitleOffset(500), 500);
  assert.equal(scheduled.length, 1);
  assert.deepEqual(scheduled[0].options, {
    sessionId: 3,
    offsetMs: 500,
    language: "pt-BR",
    label: EXTERNAL_SUBTITLE_LABEL,
  });

  const snapshot = { tracks: [] };
  await scheduled[0].onComplete(snapshot);
  const [call] = presented(calls, "presentNativeSubtitleSnapshot");
  assert.equal(call[1], snapshot);
  assert.equal(call[2].selectedTrack, 2);
  assert.equal(call[2].sessionId, 3);
  assert.equal(call[2].emitAvailable, true);
  call[2].selectTrack(1);
  assert.deepEqual(calls.subtitleSelections, [1]);

  state.sessionId = 9;
  assert.equal(await scheduled[0].onComplete(snapshot), false);
  assert.equal(presented(calls, "presentNativeSubtitleSnapshot").length, 1);
});

test("setSubtitleOffset stops when the presentation rejects the value", async () => {
  const native = { scheduleReload: () => assert.fail("should not schedule") };
  const { operations, state } = createHarness({ native });
  state.presentation = { presentSubtitleOffset: () => false };

  assert.equal(await operations.setSubtitleOffset(Number.NaN), false);
});

test("refreshAudioTracks presents refreshed tracks or the orchestrator snapshot", async () => {
  const orchestrator = {
    refreshAudioTracks: async () => undefined,
    trackSnapshot: () => ({ audioTracks: [{ id: 0 }, { id: 1 }], selectedAudioTrack: 1 }),
  };
  const { calls, operations, state } = createHarness({ orchestrator });
  state.presentation = { presentAudioTracks: (options) => options.tracks };

  assert.deepEqual(await operations.refreshAudioTracks(), [{ id: 0 }, { id: 1 }]);
  const [call] = presented(calls, "presentAudioTracks");
  assert.equal(call[1].activeTrack, 1);
  assert.equal(call[1].preferredTrack, 1);
  assert.equal(call[1].sessionId, 3);
  call[1].selectTrack(0);
  assert.deepEqual(calls.audioSelections, [0]);

  orchestrator.refreshAudioTracks = async () => [{ id: 7 }];
  assert.deepEqual(await operations.refreshAudioTracks(), [{ id: 7 }]);
});

test("refreshSubtitleTracks passes subtitle enablement and drops stale sessions", async () => {
  let supersede = false;
  const harness = createHarness({
    orchestrator: {
      refreshSubtitleTracks: async () => {
        if (supersede) harness.state.sessionId = 8;
        return [{ id: 0 }];
      },
      trackSnapshot: () => ({ subtitleTracks: [], selectedSubtitleTrack: 0 }),
    },
  });
  harness.state.presentation = { presentSubtitleTracks: (options) => options.tracks };

  assert.deepEqual(await harness.operations.refreshSubtitleTracks(), [{ id: 0 }]);
  const [call] = presented(harness.calls, "presentSubtitleTracks");
  assert.equal(call[1].subtitlesEnabled, true);
  assert.equal(call[1].preferredTrack, 0);
  assert.equal(call[1].activeTrack, 0);

  supersede = true;
  assert.equal(await harness.operations.refreshSubtitleTracks(), false);
  assert.equal(presented(harness.calls, "presentSubtitleTracks").length, 1);
});

test("loadExternalSubtitle keeps the lease only after the engine accepted the subtitle", async () => {
  const leases = [];
  const loads = [];
  const resolver = {
    resolve: async (options) => {
      const lease = createLease(`blob:${leases.length}`);
      leases.push({ options, lease });
      return lease;
    },
  };
  const orchestrator = { loadExternalSubtitle: async (options) => loads.push(options) && true };
  const { calls, operations } = createHarness({ orchestrator, resolver });

  assert.equal(await operations.loadExternalSubtitle(), true);
  assert.deepEqual(leases[0].options, {
    sessionId: 3,
    imdbId: "tt0111161",
    language: "pt-BR",
    offsetMs: 0,
  });
  assert.deepEqual(loads, [{ source: "blob:0", lang: "pt-BR", title: EXTERNAL_SUBTITLE_LABEL }]);
  assert.equal(operations.externalSubtitleLease, leases[0].lease);
  assert.equal(calls.subtitleRefreshes, 1);

  assert.equal(await operations.loadExternalSubtitle(), true);
  assert.equal(leases[0].lease.released, 1);
  assert.equal(operations.externalSubtitleLease, leases[1].lease);

  operations.destroy();
  assert.equal(leases[1].lease.released, 1);
  assert.equal(operations.externalSubtitleLease, null);
  operations.destroy();
  assert.equal(leases[1].lease.released, 1);
});

test("loadExternalSubtitle releases the lease when the engine rejects it or the session moved on", async () => {
  const lease = createLease("blob:x");
  const resolver = { resolve: async () => lease };
  const rejected = createHarness({
    resolver,
    orchestrator: { loadExternalSubtitle: async () => false },
  });
  assert.equal(await rejected.operations.loadExternalSubtitle(), false);
  assert.equal(lease.released, 1);
  assert.equal(rejected.calls.subtitleRefreshes, 0);

  const stale = createHarness({
    resolver: {
      resolve: async () => {
        stale.state.sessionId = 5;
        return createLease("blob:y");
      },
    },
    orchestrator: { loadExternalSubtitle: async () => assert.fail("should not load") },
  });
  assert.equal(await stale.operations.loadExternalSubtitle(), false);

  const failing = createHarness({
    resolver: {
      resolve: async () => {
        throw new Error("network");
      },
    },
  });
  assert.equal(await failing.operations.loadExternalSubtitle(), false);
});

test("loadExternalSubtitle skips without an imdb id, AVPlayer, or when the language exists", async () => {
  const resolver = { resolve: async () => assert.fail("should not resolve") };

  const noImdb = createHarness({ resolver, state: { imdbId: null } });
  assert.equal(await noImdb.operations.loadExternalSubtitle(), false);

  const noAvPlayer = createHarness({ resolver, state: { avPlayer: false } });
  assert.equal(await noAvPlayer.operations.loadExternalSubtitle(), false);

  const existing = createHarness({
    resolver,
    state: { subtitleTracks: [{ language: "por", label: "Português" }] },
  });
  assert.equal(await existing.operations.loadExternalSubtitle(), false);
});

test("loadNativeExternalSubtitle only runs for torrent sources and presents the preferred track", async () => {
  const loads = [];
  const snapshot = { tracks: [{ id: 0 }] };
  const native = { load: async (options) => loads.push(options) && snapshot };

  const movie = createHarness({ native, state: { sourceType: "movie" } });
  assert.equal(await movie.operations.loadNativeExternalSubtitle(), false);
  assert.deepEqual(loads, []);

  const { calls, operations } = createHarness({ native });
  assert.equal(await operations.loadNativeExternalSubtitle(undefined, true), snapshot);
  assert.deepEqual(loads, [
    {
      sessionId: 3,
      force: true,
      language: "pt-BR",
      label: EXTERNAL_SUBTITLE_LABEL,
      offsetMs: 250,
    },
  ]);
  const [call] = presented(calls, "presentNativeSubtitleSnapshot");
  assert.equal(call[1], snapshot);
  assert.equal(call[2].selectedTrack, 0);

  const disabled = createHarness({ native, state: { subtitlesEnabled: false } });
  await disabled.operations.loadNativeExternalSubtitle();
  assert.equal(presented(disabled.calls, "presentNativeSubtitleSnapshot")[0][2].selectedTrack, -1);
});

test("reloadNativeExternalSubtitle reloads with the current offset and drops stale sessions", async () => {
  const reloads = [];
  const snapshot = { tracks: [] };
  const native = { reload: async (options) => reloads.push(options) && snapshot };
  const { calls, operations } = createHarness({ native });

  await operations.reloadNativeExternalSubtitle();
  assert.deepEqual(reloads, [
    { sessionId: 3, offsetMs: 250, language: "pt-BR", label: EXTERNAL_SUBTITLE_LABEL },
  ]);
  assert.equal(presented(calls, "presentNativeSubtitleSnapshot")[0][2].selectedTrack, 2);

  const stale = createHarness({
    native: {
      reload: async () => {
        stale.state.sessionId = 10;
        return snapshot;
      },
    },
  });
  assert.equal(await stale.operations.reloadNativeExternalSubtitle(1), false);
  assert.equal(presented(stale.calls, "presentNativeSubtitleSnapshot").length, 0);
});

test("clearNativeSubtitlePresentation routes selections back through the host", () => {
  const { calls, operations, state } = createHarness();
  state.presentation = { clearSubtitlePresentation: () => "cleared" };

  assert.equal(operations.clearNativeSubtitlePresentation(), "cleared");
  const [call] = presented(calls, "clearSubtitlePresentation");
  assert.equal(call[1].sessionId, 3);
  call[1].selectTrack(4);
  assert.deepEqual(calls.subtitleSelections, [4]);
});
