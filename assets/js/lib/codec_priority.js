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

import {playerLogger as log} from "./logger";
import {detectVideoCodecs, getCapabilitySummary} from "./codec_detector";
import {checkHardwareSupport, isWebCodecsSupported, WEBCODECS_CONFIGS} from "./webcodecs_decoder";

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
 * Recommended max bitrates per codec at different resolutions (kbps)
 * Based on streaming best practices and codec efficiency
 */
export const CODEC_BITRATE_TARGETS = {
    av1: {
        2160: 12000, // 4K
        1440: 8000, // 1440p
        1080: 4500, // 1080p
        720: 2500, // 720p
        480: 1200, // 480p
        360: 600, // 360p
    },
    hevc: {
        2160: 15000,
        1440: 10000,
        1080: 6000,
        720: 3500,
        480: 1500,
        360: 800,
    },
    vp9: {
        2160: 16000,
        1440: 11000,
        1080: 6500,
        720: 3800,
        480: 1700,
        360: 900,
    },
    h264: {
        2160: 25000,
        1440: 16000,
        1080: 8000,
        720: 5000,
        480: 2500,
        360: 1000,
    },
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
    return configs.main || configs.high || configs.main8 || configs.profile0 || Object.values(configs)[0];
}

/**
 * Calculate optimal bitrate for a codec at a given resolution
 * @param {string} codec - Codec name
 * @param {number} height - Video height
 * @param {number} availableBandwidth - Available bandwidth in kbps
 * @returns {number} Recommended bitrate in kbps
 */
export function getOptimalBitrate(codec, height, availableBandwidth) {
    const targets = CODEC_BITRATE_TARGETS[codec] || CODEC_BITRATE_TARGETS.h264;

    // Find closest resolution tier
    const resolutions = Object.keys(targets)
        .map(Number)
        .sort((a, b) => b - a);
    let targetRes = resolutions.find((r) => height >= r) || resolutions[resolutions.length - 1];

    const targetBitrate = targets[targetRes];

    // Cap at 80% of available bandwidth for stability
    const maxBitrate = availableBandwidth * 0.8;

    return Math.min(targetBitrate, maxBitrate);
}

/**
 * Select the best quality level from HLS levels based on codec and network
 * @param {Array} levels - HLS.js levels array
 * @param {Object} options - Selection options
 * @returns {{levelIndex: number, level: Object, reason: string}}
 */
export function selectOptimalQuality(levels, options = {}) {
    const {
        availableBandwidth = 5000, // kbps
        preferredCodec = null,
        maxHeight = 2160,
        minHeight = 360,
        preferEfficiency = true,
    } = options;

    if (!levels || levels.length === 0) {
        return {levelIndex: -1, level: null, reason: "No levels available"};
    }

    // Group levels by codec
    const levelsByCodec = new Map();
    levels.forEach((level, index) => {
        const codec = detectLevelCodec(level);
        if (!levelsByCodec.has(codec)) {
            levelsByCodec.set(codec, []);
        }
        levelsByCodec.get(codec).push({...level, index});
    });

    // Determine codec priority
    const codecPriority = preferEfficiency
        ? ["av1", "hevc", "vp9", "h264", "unknown"]
        : ["h264", "vp9", "hevc", "av1", "unknown"];

    // If preferred codec specified and available, use it
    if (preferredCodec && levelsByCodec.has(preferredCodec)) {
        const codecLevels = levelsByCodec.get(preferredCodec);
        const selected = selectBestLevelForBandwidth(codecLevels, availableBandwidth, maxHeight, minHeight);
        if (selected) {
            return {
                levelIndex: selected.index,
                level: selected,
                reason: `Selected ${preferredCodec} (preferred)`,
            };
        }
    }

    // Try codecs in priority order
    for (const codec of codecPriority) {
        if (!levelsByCodec.has(codec)) continue;

        const codecLevels = levelsByCodec.get(codec);
        const efficiency = CODEC_EFFICIENCY[codec] || 1.0;

        // Adjust bandwidth expectation based on codec efficiency
        const adjustedBandwidth = availableBandwidth / efficiency;

        const selected = selectBestLevelForBandwidth(codecLevels, adjustedBandwidth, maxHeight, minHeight);
        if (selected) {
            return {
                levelIndex: selected.index,
                level: selected,
                reason: `Selected ${codec} level (${selected.height}p @ ${Math.round(selected.bitrate / 1000)}kbps)`,
            };
        }
    }

    // Fallback: just pick the lowest level
    return {
        levelIndex: 0,
        level: levels[0],
        reason: "Fallback to lowest level",
    };
}

/**
 * Detect codec from HLS level
 */
function detectLevelCodec(level) {
    const codecs = level.videoCodec || level.codecs || "";

    if (codecs.includes("av01") || codecs.includes("av1")) return "av1";
    if (codecs.includes("hvc1") || codecs.includes("hev1") || codecs.includes("hevc")) return "hevc";
    if (codecs.includes("vp09") || codecs.includes("vp9")) return "vp9";
    if (codecs.includes("avc1") || codecs.includes("h264")) return "h264";
    if (codecs.includes("vp8")) return "vp8";

    return "unknown";
}

/**
 * Select best level that fits within bandwidth constraints
 */
function selectBestLevelForBandwidth(levels, bandwidth, maxHeight, minHeight) {
    // Filter by resolution constraints
    const validLevels = levels.filter(
        (l) => l.height >= minHeight && l.height <= maxHeight && l.bitrate <= bandwidth * 1000,
    );

    if (validLevels.length === 0) {
        // If nothing fits, pick the lowest bitrate that fits resolution
        const resFiltered = levels.filter((l) => l.height >= minHeight && l.height <= maxHeight);
        if (resFiltered.length > 0) {
            return resFiltered.reduce((a, b) => (a.bitrate < b.bitrate ? a : b));
        }
        return null;
    }

    // Pick highest quality that fits
    return validLevels.reduce((a, b) => (a.bitrate > b.bitrate ? a : b));
}

/**
 * Calculate bandwidth savings by codec switch
 * @param {string} fromCodec - Current codec
 * @param {string} toCodec - Target codec
 * @param {number} currentBitrate - Current bitrate in kbps
 * @returns {{savedBandwidth: number, percentSaved: number, equivalentBitrate: number}}
 */
export function calculateBandwidthSavings(fromCodec, toCodec, currentBitrate) {
    const fromEfficiency = CODEC_EFFICIENCY[fromCodec] || 1.0;
    const toEfficiency = CODEC_EFFICIENCY[toCodec] || 1.0;

    // Calculate equivalent bitrate in target codec for same quality
    const equivalentBitrate = currentBitrate * (toEfficiency / fromEfficiency);
    const savedBandwidth = currentBitrate - equivalentBitrate;
    const percentSaved = (savedBandwidth / currentBitrate) * 100;

    return {
        savedBandwidth: Math.round(savedBandwidth),
        percentSaved: Math.round(percentSaved),
        equivalentBitrate: Math.round(equivalentBitrate),
    };
}

/**
 * Get codec recommendation based on device and network
 * @param {Object} options
 * @returns {Promise<{codec: string, reason: string, alternatives: Array}>}
 */
export async function getCodecRecommendation(options = {}) {
    const {networkQuality = "good", deviceMemory = 8, cpuCores = 4} = options;

    const summary = getCapabilitySummary();
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

export default {
    CODEC_EFFICIENCY,
    CODEC_BITRATE_TARGETS,
    CODEC_COMPLEXITY,
    getPrioritizedCodecs,
    getOptimalBitrate,
    selectOptimalQuality,
    calculateBandwidthSavings,
    getCodecRecommendation,
    CodecAwareABR,
};
