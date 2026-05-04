/**
 * Codec Priority Manager
 *
 * Manages codec selection priority and bitrate optimization.
 * AV1 provides ~30% better compression than H.265, enabling better quality at lower bandwidth.
 *
 * Features:
 * - Intelligent codec prioritization (AV1 > HEVC > VP9 > H.264)
 * - Bitrate optimization per codec efficiency
 * - Network-aware quality selection
 * - Device capability matching
 */

import { detectVideoCodecs } from "./codec_detector";
import { playerLogger as log } from "./logger";
import { checkHardwareSupport, isWebCodecsSupported, WEBCODECS_CONFIGS } from "./webcodecs_decoder";

/**
 * Codec efficiency factors relative to H.264
 * Lower is better (requires less bitrate for same quality)
 */
export const CODEC_EFFICIENCY = {
  av1: 0.5, // 50% of H.264 bitrate for same quality
  hevc: 0.6, // 60% of H.264 bitrate
  vp9: 0.65, // 65% of H.264 bitrate
  h264: 1.0, // Baseline
  vp8: 1.1, // Slightly worse than H.264
};

/**
 * Codec decode complexity (relative CPU usage)
 * Higher values = more CPU intensive
 */
export const CODEC_COMPLEXITY = {
  av1: 1.5, // Most complex to decode
  hevc: 1.2,
  vp9: 1.1,
  h264: 1.0, // Baseline
  vp8: 0.9, // Simplest
};

/**
 * Get prioritized codec list based on device capabilities
 * @param {Object} capabilities - Device codec capabilities
 * @param {Object} options - Selection options
 * @returns {Array<{codec: string, priority: number, hardwareAccelerated: boolean}>}
 */
export async function getPrioritizedCodecs(capabilities = null, options = {}) {
  const caps = capabilities || detectVideoCodecs();
  const {
    preferEfficiency = true, // Prefer efficient codecs (AV1/HEVC) over compatibility
    requireHardwareAcceleration = false, // Only return hardware-accelerated codecs
    maxComplexity = 2.0, // Max decode complexity (filter out heavy codecs on weak devices)
    networkQuality = "good", // 'poor', 'good', 'excellent'
  } = options;

  const codecs = [];

  // Base priority order (efficiency-first)
  const priorityOrder = preferEfficiency
    ? ["av1", "hevc", "vp9", "h264", "vp8"]
    : ["h264", "vp9", "hevc", "av1", "vp8"]; // Compatibility-first

  for (let i = 0; i < priorityOrder.length; i++) {
    const codec = priorityOrder[i];
    const capEntry = caps[codec];

    if (!capEntry?.supported) continue;

    // Check complexity threshold
    if (CODEC_COMPLEXITY[codec] > maxComplexity) continue;

    // Check hardware acceleration if required
    let hardwareAccelerated = false;
    if (isWebCodecsSupported()) {
      const codecString = getWebCodecsCodecString(codec);
      if (codecString) {
        const hwSupport = await checkHardwareSupport(codecString);
        hardwareAccelerated = hwSupport.hardwareAccelerated;
      }
    }

    if (requireHardwareAcceleration && !hardwareAccelerated) continue;

    // Calculate effective priority
    // Lower number = higher priority
    let priority = i;

    // Boost hardware-accelerated codecs
    if (hardwareAccelerated) {
      priority -= 0.5;
    }

    // Adjust for network conditions
    if (networkQuality === "poor" && CODEC_EFFICIENCY[codec] < 0.7) {
      // Boost efficient codecs on poor networks
      priority -= 0.3;
    }

    codecs.push({
      codec,
      priority,
      hardwareAccelerated,
      efficiency: CODEC_EFFICIENCY[codec],
      complexity: CODEC_COMPLEXITY[codec],
      mime: capEntry.mime,
    });
  }

  // Sort by priority (lower = better)
  codecs.sort((a, b) => a.priority - b.priority);

  return codecs;
}

/**
 * Get WebCodecs codec string for a codec name
 */
function getWebCodecsCodecString(codec) {
  const configs = WEBCODECS_CONFIGS[codec];
  if (!configs) return null;

  // Return the most common profile
  return (
    configs.main || configs.high || configs.main8 || configs.profile0 || Object.values(configs)[0]
  );
}

/**
 * Get codec recommendation based on device and network
 * @param {Object} options
 * @returns {Promise<{codec: string, reason: string, alternatives: Array}>}
 */
export async function getCodecRecommendation(options = {}) {
  const { networkQuality = "good", deviceMemory = 8, cpuCores = 4 } = options;

  const prioritized = await getPrioritizedCodecs(null, {
    preferEfficiency: networkQuality !== "excellent",
    requireHardwareAcceleration: deviceMemory < 4, // Require HW accel on low-memory devices
    maxComplexity: cpuCores < 4 ? 1.2 : 2.0, // Limit complexity on weak CPUs
    networkQuality,
  });

  if (prioritized.length === 0) {
    return {
      codec: "h264",
      reason: "Fallback to H.264 (universal support)",
      alternatives: [],
    };
  }

  const best = prioritized[0];
  const alternatives = prioritized.slice(1, 4);

  let reason = `${best.codec.toUpperCase()} selected`;
  if (best.hardwareAccelerated) {
    reason += " (hardware accelerated)";
  }
  if (best.efficiency < 0.7) {
    reason += ` - ${Math.round((1 - best.efficiency) * 100)}% more efficient than H.264`;
  }

  return {
    codec: best.codec,
    reason,
    alternatives: alternatives.map((a) => ({
      codec: a.codec,
      hardwareAccelerated: a.hardwareAccelerated,
    })),
    details: best,
  };
}

/**
 * Create a codec-aware ABR (Adaptive Bitrate) controller
 * Adjusts quality decisions based on codec efficiency
 */
export class CodecAwareABR {
  constructor(options = {}) {
    this.currentCodec = options.initialCodec || "h264";
    this.bandwidthHistory = [];
    this.maxHistoryLength = 10;
    this.safetyFactor = options.safetyFactor || 0.8;
  }

  /**
   * Record bandwidth measurement
   * @param {number} bandwidth - Measured bandwidth in kbps
   */
  recordBandwidth(bandwidth) {
    this.bandwidthHistory.push({
      bandwidth,
      timestamp: Date.now(),
      codec: this.currentCodec,
    });

    // Keep history bounded
    if (this.bandwidthHistory.length > this.maxHistoryLength) {
      this.bandwidthHistory.shift();
    }
  }

  /**
   * Get estimated bandwidth (EWMA)
   */
  getEstimatedBandwidth() {
    if (this.bandwidthHistory.length === 0) return 5000; // Default 5Mbps

    // Exponentially weighted moving average
    let weight = 1;
    let totalWeight = 0;
    let weightedSum = 0;

    for (let i = this.bandwidthHistory.length - 1; i >= 0; i--) {
      weightedSum += this.bandwidthHistory[i].bandwidth * weight;
      totalWeight += weight;
      weight *= 0.7; // Decay factor
    }

    return (weightedSum / totalWeight) * this.safetyFactor;
  }

  /**
   * Suggest quality level
   * @param {Array} levels - Available quality levels
   * @returns {{levelIndex: number, reason: string}}
   */
  suggestQuality(levels) {
    const estimatedBandwidth = this.getEstimatedBandwidth();

    return selectOptimalQuality(levels, {
      availableBandwidth: estimatedBandwidth,
      preferredCodec: this.currentCodec,
      preferEfficiency: true,
    });
  }

  /**
   * Set current codec
   */
  setCodec(codec) {
    this.currentCodec = codec;
    log.debug(`[CodecABR] Codec changed to ${codec}`);
  }
}
