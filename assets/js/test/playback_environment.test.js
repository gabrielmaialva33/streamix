import assert from "node:assert/strict";
import test from "node:test";

import {
  getPlaybackResourcePolicy,
  hasWebCodecsHevcSupport,
  isAppleTouchDevice,
  isAppleWebKitBrowser,
  isDirectStreamUrlAllowed,
  isFirefoxBrowser,
  isStandalonePwa,
  readEngineFlag,
  scheduleLowPriority,
} from "../player/playback_environment.js";

test("reads experimental engine flags without requiring browser storage", () => {
  assert.equal(readEngineFlag({ dataset: { featureAvbridge: "true" } }, "avbridge"), true);
  assert.equal(
    readEngineFlag({}, "h265web", {
      getItem(key) {
        return key === "streamix:h265web" ? "true" : null;
      },
    }),
    true,
  );
  assert.equal(
    readEngineFlag({}, "avbridge", {
      getItem() {
        throw new Error("storage blocked");
      },
    }),
    false,
  );
});

test("classifies playback environment capabilities", () => {
  assert.equal(hasWebCodecsHevcSupport({ VideoDecoder() {} }), true);
  assert.equal(isFirefoxBrowser({ userAgent: "Mozilla Firefox/140" }), true);
  assert.equal(
    isAppleWebKitBrowser({
      userAgent:
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 CriOS/140 Mobile/15E148 Safari/604.1",
      platform: "iPhone",
      maxTouchPoints: 5,
      vendor: "Google Inc.",
    }),
    true,
  );
  assert.equal(
    isAppleWebKitBrowser({
      userAgent:
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140 Safari/537.36",
      platform: "MacIntel",
      maxTouchPoints: 0,
      vendor: "Google Inc.",
    }),
    false,
  );
  assert.equal(
    isAppleWebKitBrowser({
      userAgent:
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15",
      platform: "MacIntel",
      maxTouchPoints: 0,
      vendor: "Apple Computer, Inc.",
    }),
    true,
  );
  assert.equal(
    isAppleTouchDevice({
      userAgent: "Mozilla/5.0",
      platform: "MacIntel",
      maxTouchPoints: 5,
    }),
    true,
  );
  assert.equal(
    isStandalonePwa({
      navigatorRef: { standalone: false },
      windowRef: { matchMedia: () => ({ matches: true }) },
    }),
    true,
  );
});

test("blocks mixed-content direct stream retries without rejecting secure URLs", () => {
  assert.equal(isDirectStreamUrlAllowed("http://provider.test/live.ts", "https:"), false);
  assert.equal(isDirectStreamUrlAllowed("https://provider.test/live.ts", "https:"), true);
  assert.equal(isDirectStreamUrlAllowed("http://provider.test/live.ts", "http:"), true);
  assert.equal(isDirectStreamUrlAllowed("", "https:"), false);
});

test("avoids speculative probes on constrained devices and networks", () => {
  assert.deepEqual(
    getPlaybackResourcePolicy({
      connection: { saveData: false, effectiveType: "2g" },
      deviceMemory: 8,
      hardwareConcurrency: 8,
    }),
    {
      saveData: false,
      effectiveType: "2g",
      deviceMemory: 8,
      cpuCores: 8,
      lowEndDevice: false,
      constrainedNetwork: true,
      avoidSpeculativeWork: true,
      shouldRunAdvancedDiagnostics: false,
      shouldProbeTracks: false,
      reason: "network-2g",
    },
  );
});

test("schedules low-priority work with the timeout fallback", () => {
  let scheduledTimeout;
  let clearedTimeout;
  const windowRef = {
    setTimeout(_callback, timeout) {
      scheduledTimeout = timeout;
      return 42;
    },
    clearTimeout(id) {
      clearedTimeout = id;
    },
  };

  const cancel = scheduleLowPriority(() => {}, { timeout: 2500, windowRef });
  assert.equal(scheduledTimeout, 1000);
  cancel();
  assert.equal(clearedTimeout, 42);
});
