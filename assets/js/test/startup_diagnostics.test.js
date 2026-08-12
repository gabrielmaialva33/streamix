import assert from "node:assert/strict";
import test from "node:test";

import {
  collectStartupDiagnostics,
  detectAdvancedCapabilities,
  networkQualityFromInfo,
} from "../player/startup_diagnostics.js";

const createLogger = () => {
  const entries = [];
  return {
    entries,
    debug(...args) {
      entries.push(["debug", ...args]);
    },
    warn(...args) {
      entries.push(["warn", ...args]);
    },
  };
};

test("normalizes Network Information API values for codec selection", () => {
  assert.equal(networkQualityFromInfo(), "good");
  assert.equal(networkQualityFromInfo({ effectiveType: "slow-2g" }), "poor");
  assert.equal(networkQualityFromInfo({ effectiveType: "2g" }), "poor");
  assert.equal(networkQualityFromInfo({ effectiveType: "3g" }), "good");
  assert.equal(networkQualityFromInfo({ effectiveType: "4g" }), "excellent");
});

test("skips expensive startup probes when the resource policy is constrained", async () => {
  const logger = createLogger();
  const policy = {
    reason: "save-data",
    shouldRunAdvancedDiagnostics: false,
  };
  const report = await collectStartupDiagnostics({
    logger,
    policy,
    dependencies: {
      getCapabilitySummary: () => ({ hls: true }),
      getMSEWorkerCapabilityReport: () => ({ supported: false }),
      isMSEInWorkersSupported: () => false,
      isWebCodecsSupported: () => true,
      runQuickDiagnostics: async () => ({
        allPassed: false,
        results: [
          { name: "network", passed: false },
          { name: "storage", passed: true },
        ],
      }),
    },
  });

  assert.deepEqual(report.capabilities, { hls: true });
  assert.equal(report.advanced.skipped, true);
  assert.equal(report.advanced.reason, "save-data");
  assert.equal(report.advanced.webCodecs.supported, true);
  assert.equal(report.advanced.codecRecommendation, null);
  assert.equal(logger.entries.filter(([level]) => level === "warn").length, 1);
});

test("isolates optional advanced probe failures from the remaining capability report", async () => {
  const logger = createLogger();
  let recommendationInput;
  const capabilities = await detectAdvancedCapabilities({
    logger,
    navigatorRef: {
      connection: { effectiveType: "4g" },
      deviceMemory: 8,
      hardwareConcurrency: 12,
    },
    dependencies: {
      getCodecCapabilityReport: async () => ({ hevc: true }),
      getCodecRecommendation: async (input) => {
        recommendationInput = input;
        return { codec: "hevc" };
      },
      getFeatureRecommendations: () => ({
        preferAV1: false,
        useMSEWorkers: true,
        useWebCodecs: true,
      }),
      getMSEWorkerCapabilityReport: () => ({ supported: true }),
      getWebCodecsCapabilityReport: async () => {
        throw new Error("probe unavailable");
      },
      isMSEInWorkersSupported: () => true,
      isWebCodecsSupported: () => true,
    },
  });

  assert.deepEqual(recommendationInput, {
    networkQuality: "excellent",
    deviceMemory: 8,
    cpuCores: 12,
  });
  assert.equal(capabilities.webCodecs.report, null);
  assert.deepEqual(capabilities.codecRecommendation, { codec: "hevc" });
  assert.equal(capabilities.featureRecommendations.useWebCodecs, true);
  assert.equal(
    logger.entries.some((entry) => entry.includes("[VideoPlayer] WebCodecs report failed:")),
    true,
  );
});
