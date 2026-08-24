import assert from "node:assert/strict";
import test from "node:test";

import {
  assertEngineSelection,
  ENGINE_EVENT,
  ENGINE_ID,
  ENGINE_SELECTION,
  engineIdFromRuntime,
  isEngineId,
  isEngineSelection,
  normalizeEngineId,
  PLAYBACK_STATE,
} from "../player/engine_contract.js";

test("keeps runtime engine IDs distinct from selection decisions", () => {
  assert.equal(isEngineId(ENGINE_ID.NATIVE), true);
  assert.equal(isEngineId(ENGINE_ID.HLS), true);
  assert.equal(isEngineId(ENGINE_ID.UNKNOWN), true);

  assert.equal(isEngineSelection(ENGINE_SELECTION.NATIVE), true);
  assert.equal(isEngineSelection(ENGINE_SELECTION.HLS_JS), true);
  assert.equal(isEngineSelection(ENGINE_SELECTION.MPEGTS_FLV), true);
  assert.equal(isEngineSelection(ENGINE_SELECTION.FLV_UNSUPPORTED), true);

  assert.equal(isEngineSelection(ENGINE_ID.HLS), false);
  assert.equal(isEngineSelection(ENGINE_ID.UNKNOWN), false);
});

test("normalizes every selection into a bounded telemetry engine ID", () => {
  const cases = [
    [ENGINE_SELECTION.NATIVE, ENGINE_ID.NATIVE],
    [ENGINE_SELECTION.HLS_JS, ENGINE_ID.HLS],
    [ENGINE_SELECTION.MPEGTS, ENGINE_ID.MPEGTS],
    [ENGINE_SELECTION.MPEGTS_FLV, ENGINE_ID.MPEGTS],
    [ENGINE_SELECTION.AVPLAYER, ENGINE_ID.AVPLAYER],
    [ENGINE_SELECTION.AVBRIDGE, ENGINE_ID.AVBRIDGE],
    [ENGINE_SELECTION.H265WEB, ENGINE_ID.H265WEB],
    [ENGINE_SELECTION.FLV_UNSUPPORTED, ENGINE_ID.UNKNOWN],
    ["unexpected-engine", ENGINE_ID.UNKNOWN],
    [null, ENGINE_ID.UNKNOWN],
  ];

  for (const [selection, expected] of cases) {
    assert.equal(normalizeEngineId(selection), expected);
  }
});

test("rejects selections outside the explicit control-flow contract", () => {
  assert.equal(assertEngineSelection(ENGINE_SELECTION.HLS_JS), ENGINE_SELECTION.HLS_JS);

  assert.throws(
    () => assertEngineSelection(ENGINE_ID.HLS),
    /Unknown playback engine selection: hls/,
  );
});

test("derives the active canvas engine using the established runtime precedence", () => {
  const runtime = {
    usingAVPlayer: true,
    usingH265web: true,
    usingAvbridge: true,
  };

  assert.equal(engineIdFromRuntime(runtime), ENGINE_ID.AVPLAYER);

  runtime.usingAVPlayer = false;
  assert.equal(engineIdFromRuntime(runtime), ENGINE_ID.H265WEB);

  runtime.usingH265web = false;
  assert.equal(engineIdFromRuntime(runtime), ENGINE_ID.AVBRIDGE);
});

test("prefers the registered media-element engine over transport introspection", () => {
  assert.equal(
    engineIdFromRuntime({
      mediaElementEngine: { id: ENGINE_ID.MPEGTS },
      streamLoader: {
        getHls: () => ({ active: true }),
      },
    }),
    ENGINE_ID.MPEGTS,
  );
});

test("reports HLS and MPEG-TS engines managed by the shared stream loader", () => {
  assert.equal(
    engineIdFromRuntime({
      streamLoader: {
        getHls: () => ({ active: true }),
        getMpegtsPlayer: () => ({ active: true }),
      },
    }),
    ENGINE_ID.HLS,
  );

  assert.equal(
    engineIdFromRuntime({
      streamLoader: {
        getHls: () => null,
        getMpegtsPlayer: () => ({ active: true }),
      },
    }),
    ENGINE_ID.MPEGTS,
  );

  assert.equal(engineIdFromRuntime(), ENGINE_ID.NATIVE);
});

test("runtime identity remains non-throwing during teardown", () => {
  assert.equal(
    engineIdFromRuntime({
      streamLoader: {
        getHls() {
          throw new Error("destroyed");
        },
      },
    }),
    ENGINE_ID.NATIVE,
  );
});

test("publishes immutable lifecycle and event vocabularies", () => {
  assert.equal(Object.isFrozen(PLAYBACK_STATE), true);
  assert.equal(Object.isFrozen(ENGINE_EVENT), true);
  assert.equal(PLAYBACK_STATE.RECOVERING, "recovering");
  assert.equal(ENGINE_EVENT.FATAL_ERROR, "fatal_error");
});
