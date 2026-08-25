import assert from "node:assert/strict";
import test from "node:test";

import {
  createPlayerDiagnosticsController,
  sanitizeDiagnosticPayload,
} from "../player/player_diagnostics_controller.js";

function createHarness(overrides = {}) {
  const events = [];
  const shownErrors = [];
  const recommendations = [];
  const logs = { debug: [], warn: [] };

  const controller = createPlayerDiagnosticsController({
    collectStartup: async ({ policy }) => ({
      advanced: { codecRecommendation: { codec: "av1" } },
      policy,
      quick: { allPassed: true },
    }),
    diagnose: async () => ({ recommendations: [] }),
    getDebugContext: () => ({ engine: "hls" }),
    getErrorContext: () => ({ contentType: "movie" }),
    getResourcePolicy: () => ({ shouldRunAdvancedDiagnostics: true }),
    initCodecAwareABR: (recommendation) => recommendations.push(recommendation),
    logger: {
      debug: (...args) => logs.debug.push(args),
      warn: (...args) => logs.warn.push(args),
    },
    pushEvent: (event, payload) => events.push({ event, payload }),
    showPlaybackError: (message) => shownErrors.push(message),
    ...overrides,
  });

  return {
    controller,
    events,
    logs,
    recommendations,
    shownErrors,
  };
}

test("startup diagnostics emit a bounded report and initialize codec-aware ABR", async () => {
  const harness = createHarness();

  const report = await harness.controller.runStartup();

  assert.equal(report.quick.allPassed, true);
  assert.deepEqual(harness.recommendations, [{ codec: "av1" }]);
  assert.deepEqual(harness.events, [
    {
      event: "device_diagnostics",
      payload: {
        advanced: { codecRecommendation: { codec: "av1" } },
        policy: { shouldRunAdvancedDiagnostics: true },
        quick: { allPassed: true },
      },
    },
  ]);
});

test("startup diagnostics failures remain non-critical", async () => {
  const harness = createHarness({
    collectStartup: async () => {
      throw new Error("probe failed");
    },
  });

  assert.equal(await harness.controller.runStartup(), null);
  assert.deepEqual(harness.events, []);
  assert.equal(harness.logs.debug.length, 1);
});

test("showError always presents the playback error without forcing diagnostics", async () => {
  let diagnoseCalls = 0;
  const harness = createHarness({
    diagnose: async () => {
      diagnoseCalls += 1;
      return {};
    },
  });

  assert.equal(await harness.controller.showError("Playback unavailable", new Error("x")), null);
  assert.deepEqual(harness.shownErrors, ["Playback unavailable"]);
  assert.equal(diagnoseCalls, 0);
});

test("showError emits a safe non-native player suggestion", async () => {
  const observedContexts = [];
  const diagnosis = {
    recommendations: ["Try the compatibility engine"],
    suggestedPlayer: {
      player: "avplayer",
      reason: "codec_not_supported",
    },
  };
  const harness = createHarness({
    diagnose: async (_error, context) => {
      observedContexts.push(context);
      return diagnosis;
    },
    getErrorContext: () => ({
      contentType: "movie",
      sourceType: "gindex",
      streamType: "mkv",
    }),
  });

  assert.equal(
    await harness.controller.showError("Playback unavailable", new Error("decode failed"), true),
    diagnosis,
  );
  assert.deepEqual(observedContexts, [
    {
      contentType: "movie",
      sourceType: "gindex",
      streamType: "mkv",
    },
  ]);
  assert.deepEqual(harness.events, [
    {
      event: "diagnostic_suggestion",
      payload: {
        player: "avplayer",
        reason: "codec_not_supported",
        recommendations: ["Try the compatibility engine"],
      },
    },
  ]);
});

test("diagnostic failures do not replace the original playback error", async () => {
  const harness = createHarness({
    diagnose: async () => {
      throw new Error("diagnostics unavailable");
    },
  });

  assert.equal(
    await harness.controller.showError("Playback unavailable", new Error("decode failed"), true),
    null,
  );
  assert.deepEqual(harness.shownErrors, ["Playback unavailable"]);
  assert.equal(harness.logs.warn.length, 1);
});

test("debug reports redact URL, credential and embedded URL values", () => {
  const circular = { name: "loop" };
  circular.self = circular;

  const harness = createHarness({
    getDebugContext: () => ({
      current_url: "https://user:pass@example.test/movie.m3u8?token=secret",
      current_url_present: true,
      engine: "hls",
      nested: circular,
      user_agent: "Streamix Test Browser",
    }),
  });

  const payload = harness.controller.reportDebug("manifest_error", {
    authorization: "Bearer secret",
    error_detail: "Failed https://example.test/segment.ts?token=secret",
    selected_engine: "mpegts",
  });

  assert.deepEqual(payload, {
    authorization: "[redacted]",
    current_url: "[redacted]",
    current_url_present: true,
    engine: "hls",
    error_detail: "Failed [redacted-url]",
    nested: { name: "loop", self: "[circular]" },
    selected_engine: "mpegts",
    stage: "manifest_error",
    user_agent: "Streamix Test Browser",
  });
  assert.deepEqual(harness.events, [{ event: "player_debug", payload }]);
});

test("sanitization bounds strings, arrays and object depth", () => {
  const payload = sanitizeDiagnosticPayload({
    array: Array.from({ length: 30 }, (_, index) => index),
    deeply: { one: { two: { three: { four: { value: true } } } } },
    note: "x".repeat(600),
  });

  assert.equal(payload.array.length, 25);
  assert.equal(payload.deeply.one.two.three, "[truncated]");
  assert.equal(payload.note.length, 501);
  assert.equal(payload.note.endsWith("…"), true);
});

test("event transport failures are contained", () => {
  const harness = createHarness({
    pushEvent: () => {
      throw new Error("disconnected");
    },
  });

  assert.deepEqual(harness.controller.reportDebug("teardown"), {
    engine: "hls",
    stage: "teardown",
  });
  assert.equal(harness.logs.debug.length, 1);
});
