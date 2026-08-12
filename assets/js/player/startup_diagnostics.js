import { playerLogger as log } from "../core/logger.js";
import { getCapabilitySummary, getCodecCapabilityReport } from "../media/codec_detector.js";
import { getCodecRecommendation } from "../media/codec_priority.js";
import { getFeatureRecommendations } from "../media/streaming_config.js";
import { getWebCodecsCapabilityReport, isWebCodecsSupported } from "../media/webcodecs_decoder.js";
import { getMSEWorkerCapabilityReport, isMSEInWorkersSupported } from "../media/worker_mse.js";
import { runQuickDiagnostics } from "./player_diagnostics.js";

const defaultDependencies = {
  getCapabilitySummary,
  getCodecCapabilityReport,
  getCodecRecommendation,
  getFeatureRecommendations,
  getMSEWorkerCapabilityReport,
  getWebCodecsCapabilityReport,
  isMSEInWorkersSupported,
  isWebCodecsSupported,
  runQuickDiagnostics,
};

const resolveDependencies = (overrides) => ({ ...defaultDependencies, ...overrides });

export function networkQualityFromInfo(networkInfo) {
  switch (networkInfo?.effectiveType) {
    case "slow-2g":
    case "2g":
      return "poor";
    case "4g":
      return "excellent";
    default:
      return "good";
  }
}

export async function detectAdvancedCapabilities({
  dependencies = {},
  logger = log,
  navigatorRef = globalThis.navigator,
} = {}) {
  const deps = resolveDependencies(dependencies);
  const capabilities = {
    webCodecs: {
      supported: deps.isWebCodecsSupported(),
      report: null,
    },
    mseWorkers: {
      supported: deps.isMSEInWorkersSupported(),
      report: deps.getMSEWorkerCapabilityReport(),
    },
    codecRecommendation: null,
    featureRecommendations: null,
  };

  if (capabilities.webCodecs.supported) {
    try {
      capabilities.webCodecs.report = await deps.getWebCodecsCapabilityReport();
      logger.debug("[VideoPlayer] WebCodecs available:", capabilities.webCodecs.report);
    } catch (error) {
      logger.debug("[VideoPlayer] WebCodecs report failed:", error.message);
    }
  }

  try {
    capabilities.codecRecommendation = await deps.getCodecRecommendation({
      networkQuality: networkQualityFromInfo(navigatorRef?.connection),
      deviceMemory: navigatorRef?.deviceMemory || 4,
      cpuCores: navigatorRef?.hardwareConcurrency || 4,
    });
    logger.debug("[VideoPlayer] Codec recommendation:", capabilities.codecRecommendation);
  } catch (error) {
    logger.debug("[VideoPlayer] Codec recommendation failed:", error.message);
  }

  try {
    const fullReport = await deps.getCodecCapabilityReport();
    capabilities.featureRecommendations = deps.getFeatureRecommendations(fullReport);
    logger.debug("[VideoPlayer] Feature recommendations:", capabilities.featureRecommendations);

    if (capabilities.featureRecommendations.useWebCodecs) {
      logger.debug("[VideoPlayer] WebCodecs hardware acceleration available");
    }
    if (capabilities.featureRecommendations.useMSEWorkers) {
      logger.debug("[VideoPlayer] MSE in Workers available - smoother UI during buffering");
    }
    if (capabilities.featureRecommendations.preferAV1) {
      logger.debug("[VideoPlayer] AV1 codec available - 30% bandwidth savings possible");
    }
  } catch (error) {
    logger.debug("[VideoPlayer] Feature recommendations failed:", error.message);
  }

  return capabilities;
}

export async function collectStartupDiagnostics({
  dependencies = {},
  logger = log,
  navigatorRef = globalThis.navigator,
  policy,
}) {
  const deps = resolveDependencies(dependencies);
  const quick = await deps.runQuickDiagnostics();

  if (!quick.allPassed) {
    logger.warn(
      "[VideoPlayer] Some startup diagnostics failed:",
      quick.results.filter((result) => !result.passed),
    );
  }

  const advanced = policy.shouldRunAdvancedDiagnostics
    ? await detectAdvancedCapabilities({ dependencies: deps, logger, navigatorRef })
    : {
        skipped: true,
        reason: policy.reason,
        webCodecs: { supported: deps.isWebCodecsSupported(), report: null },
        mseWorkers: {
          supported: deps.isMSEInWorkersSupported(),
          report: deps.getMSEWorkerCapabilityReport(),
        },
        codecRecommendation: null,
        featureRecommendations: null,
      };

  return {
    quick,
    capabilities: deps.getCapabilitySummary(),
    advanced,
    resource_policy: policy,
  };
}
