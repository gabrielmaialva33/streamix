import assert from "node:assert/strict";
import test from "node:test";

import { classifyMpegtsError, executeMpegtsDecision } from "../player/mpegts_error_policy.js";
import { canRetryDirectStream } from "../player/playback_environment.js";

test("fatal codec enums fall back to AVPlayer immediately", () => {
  assert.deepEqual(
    classifyMpegtsError(
      { errorType: "MediaError", errorDetail: "MediaCodecUnsupported" },
      { canTryAVPlayer: true },
    ),
    { action: "fallback-avplayer", reason: "MEDIA_CODEC_UNSUPPORTED" },
  );
});

test("a first network timeout cleanly retries mpegts without AVPlayer", async () => {
  const decision = classifyMpegtsError(
    { errorType: "NetworkError", errorDetail: "NetworkTimeout" },
    { canTryAVPlayer: true, maxNetworkAttempts: 2, networkAttempts: 0 },
  );
  const calls = [];

  await executeMpegtsDecision(decision, {
    cleanup: async () => {
      calls.push("cleanup");
      return true;
    },
    retryMpegts: () => calls.push("mpegts"),
    fallbackAVPlayer: () => calls.push("avplayer"),
    schedule: (callback) => callback(),
  });

  assert.equal(decision.action, "retry-mpegts");
  assert.equal(decision.counter, "network");
  assert.deepEqual(calls, ["cleanup", "mpegts"]);
});

test("an exhausted network budget falls back to AVPlayer exactly once", async () => {
  const decision = classifyMpegtsError(
    { errorType: "NetworkError", errorDetail: "NetworkUnrecoverableEarlyEof" },
    { canTryAVPlayer: true, maxNetworkAttempts: 2, networkAttempts: 2 },
  );
  let avPlayerCalls = 0;

  await executeMpegtsDecision(decision, {
    cleanup: async () => true,
    fallbackAVPlayer: () => {
      avPlayerCalls += 1;
    },
  });

  assert.equal(decision.action, "fallback-avplayer");
  assert.equal(avPlayerCalls, 1);
});

test("401 and 403 request token refresh without teardown or engine switch", async () => {
  for (const status of [401, 403]) {
    const calls = [];
    const decision = classifyMpegtsError(
      {
        errorType: "NetworkError",
        errorDetail: "NetworkStatusCodeInvalid",
        errorInfo: { response: { code: status } },
      },
      { canTryAVPlayer: true, canTryDirect: true },
    );

    await executeMpegtsDecision(decision, {
      cleanup: async () => {
        calls.push("cleanup");
        return true;
      },
      refreshToken: () => calls.push("refresh"),
      retryDirect: () => calls.push("direct"),
      fallbackAVPlayer: () => calls.push("avplayer"),
    });

    assert.deepEqual(calls, ["refresh"]);
  }
});

test("429 and 5xx statuses use the bounded network retry budget", () => {
  for (const status of [429, 500, 503]) {
    const decision = classifyMpegtsError(
      {
        errorType: "NetworkError",
        errorDetail: "NetworkStatusCodeInvalid",
        errorInfo: { code: status },
      },
      { canTryAVPlayer: true, maxNetworkAttempts: 2, networkAttempts: 0 },
    );

    assert.equal(decision.action, "retry-mpegts");
    assert.equal(decision.counter, "network");
    assert.ok(decision.delayMs > 0);
  }
});

test("mixed-content direct URLs preserve the HTTPS proxy for network and codec errors", () => {
  const canTryDirect = canRetryDirectStream({
    currentUrl: "https://streamix.test/api/stream/proxy?token=test",
    pageProtocol: "https:",
    streamUrl: "http://provider.test/live/channel.ts",
    useProxy: true,
  });

  assert.equal(canTryDirect, false);
  assert.equal(
    classifyMpegtsError(
      {
        errorType: "NetworkError",
        errorDetail: "NetworkStatusCodeInvalid",
        errorInfo: { code: 503 },
      },
      { canTryAVPlayer: true, canTryDirect, networkAttempts: 0 },
    ).action,
    "retry-mpegts",
  );
  assert.equal(
    classifyMpegtsError(
      { errorType: "MediaError", errorDetail: "MediaFormatUnsupported" },
      { canTryAVPlayer: true, canTryDirect },
    ).action,
    "fallback-avplayer",
  );
});

test("proxy-to-direct precedes AVPlayer when a direct URL is available", () => {
  const decision = classifyMpegtsError(
    { errorType: "MediaError", errorDetail: "MediaFormatUnsupported" },
    { canTryAVPlayer: true, canTryDirect: true },
  );

  assert.equal(decision.action, "retry-direct");
});

test("MSE and OTHER errors receive one recreation before fallback", () => {
  for (const [errorType, errorDetail] of [
    ["MediaError", "MediaMSEError"],
    ["OtherError", "OtherError"],
  ]) {
    assert.equal(
      classifyMpegtsError({ errorType, errorDetail }, { canTryAVPlayer: true, recreateAttempts: 0 })
        .action,
      "retry-mpegts",
    );
    assert.equal(
      classifyMpegtsError({ errorType, errorDetail }, { canTryAVPlayer: true, recreateAttempts: 1 })
        .action,
      "fallback-avplayer",
    );
  }
});

test("RecoveredEarlyEof is non-fatal", () => {
  assert.equal(
    classifyMpegtsError({
      errorType: "NetworkError",
      errorDetail: "RecoveredEarlyEof",
    }).action,
    "ignore",
  );
});

test("teardown finishes before fallback and a stale session suppresses it", async () => {
  const calls = [];
  let current = true;

  await executeMpegtsDecision(
    { action: "fallback-avplayer" },
    {
      cleanup: async () => {
        calls.push("cleanup:start");
        await Promise.resolve();
        calls.push("cleanup:end");
        return true;
      },
      isCurrent: () => current,
      fallbackAVPlayer: () => calls.push("avplayer"),
    },
  );
  assert.deepEqual(calls, ["cleanup:start", "cleanup:end", "avplayer"]);

  current = false;
  await executeMpegtsDecision(
    { action: "fallback-avplayer" },
    {
      cleanup: async () => true,
      isCurrent: () => current,
      fallbackAVPlayer: () => calls.push("stale-avplayer"),
    },
  );
  assert.equal(calls.includes("stale-avplayer"), false);
});
