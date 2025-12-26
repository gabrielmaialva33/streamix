/**
 * Streaming Configuration Profiles for Streamix
 *
 * Three optimized profiles for different use cases:
 * - low_latency: Live sports/events (2-5s delay)
 * - balanced: Regular live TV (10-15s delay)
 * - quality: VOD content (maximum quality, larger buffers)
 */

export const StreamingMode = {
  LOW_LATENCY: "low_latency",
  BALANCED: "balanced",
  QUALITY: "quality",
};

export const ContentType = {
  LIVE: "live",
  VOD: "vod",
};

export const NetworkQuality = {
  POOR: "poor", // < 1Mbps
  GOOD: "good", // 1-5Mbps
  EXCELLENT: "excellent", // > 5Mbps
};

/**
 * Streaming configuration profiles for HLS.js and mpegts.js
 */
export const StreamingProfiles = {
  [StreamingMode.LOW_LATENCY]: {
    name: "Low Latency",
    description: "Optimized for live events with minimal delay",
    hls: {
      lowLatencyMode: true,
      maxBufferLength: 10,
      maxBufferSize: 20 * 1000 * 1000, // 20MB
      maxMaxBufferLength: 20,
      backBufferLength: 2,
      liveSyncDurationCount: 2,
      liveMaxLatencyDurationCount: 4,
      // ABR settings - faster adaptation
      abrBandWidthFactor: 0.9,
      abrBandWidthUpFactor: 0.7,
      abrEwmaDefaultEstimate: 500000,
      // Fragment loading - shorter timeouts
      fragLoadingTimeOut: 10000,
      fragLoadingMaxRetry: 3,
      fragLoadingRetryDelay: 500,
      // Level loading
      levelLoadingTimeOut: 8000,
      levelLoadingMaxRetry: 3,
      // Other
      startLevel: -1,
      enableWorker: true,
      maxBufferHole: 0.3,
    },
    mpegts: {
      enableWorker: true,
      enableStashBuffer: true,
      stashInitialSize: 256 * 1024, // 256KB - smaller for faster start
      autoCleanupSourceBuffer: true,
      autoCleanupMaxBackwardDuration: 30,
      autoCleanupMinBackwardDuration: 15,
      liveBufferLatencyChasing: true, // Chase latency for live
      liveBufferLatencyMaxLatency: 1.5,
      liveBufferLatencyMinRemain: 0.5,
      lazyLoad: false,
      accurateSeek: false,
      seekType: "range",
    },
  },

  [StreamingMode.BALANCED]: {
    name: "Balanced",
    description: "Good balance between latency and quality for regular live TV",
    hls: {
      lowLatencyMode: false,
      maxBufferLength: 30,
      maxBufferSize: 40 * 1000 * 1000, // 40MB
      maxMaxBufferLength: 60,
      backBufferLength: 30,
      // ABR settings - balanced
      abrBandWidthFactor: 0.85,
      abrBandWidthUpFactor: 0.6,
      abrEwmaDefaultEstimate: 500000,
      // Fragment loading
      fragLoadingTimeOut: 15000,
      fragLoadingMaxRetry: 4,
      fragLoadingRetryDelay: 1000,
      // Level loading
      levelLoadingTimeOut: 10000,
      levelLoadingMaxRetry: 4,
      // Other
      startLevel: -1,
      enableWorker: true,
      maxBufferHole: 0.5,
    },
    mpegts: {
      enableWorker: true,
      enableStashBuffer: true,
      stashInitialSize: 384 * 1024, // 384KB
      autoCleanupSourceBuffer: true,
      autoCleanupMaxBackwardDuration: 45,
      autoCleanupMinBackwardDuration: 30,
      liveBufferLatencyChasing: false, // Don't chase, prioritize stability
      lazyLoad: false,
      lazyLoadMaxDuration: 45,
      accurateSeek: false,
      seekType: "range",
    },
  },

  [StreamingMode.QUALITY]: {
    name: "Quality",
    description: "Maximum quality for VOD content with large buffers",
    hls: {
      lowLatencyMode: false,
      maxBufferLength: 60,
      maxBufferSize: 60 * 1000 * 1000, // 60MB
      maxMaxBufferLength: 120,
      backBufferLength: 120, // 2 minutes back buffer
      // ABR settings - conservative, prefer quality
      abrBandWidthFactor: 0.8,
      abrBandWidthUpFactor: 0.5,
      abrEwmaDefaultEstimate: 500000,
      // Fragment loading - longer timeouts, more retries
      fragLoadingTimeOut: 20000,
      fragLoadingMaxRetry: 6,
      fragLoadingRetryDelay: 1000,
      // Level loading
      levelLoadingTimeOut: 10000,
      levelLoadingMaxRetry: 4,
      levelLoadingRetryDelay: 1000,
      // Other
      startLevel: -1, // Auto, will ramp up to best quality
      enableWorker: true,
      maxBufferHole: 0.5,
    },
    mpegts: {
      enableWorker: true,
      enableStashBuffer: true,
      stashInitialSize: 512 * 1024, // 512KB - larger for VOD
      autoCleanupSourceBuffer: true,
      autoCleanupMaxBackwardDuration: 60,
      autoCleanupMinBackwardDuration: 30,
      liveBufferLatencyChasing: false,
      lazyLoad: true,
      lazyLoadMaxDuration: 60,
      lazyLoadRecoverDuration: 30,
      accurateSeek: true, // Accurate seeking for VOD
      seekType: "range",
    },
  },
};

/**
 * Select the optimal streaming mode based on content type and network quality
 * @param {string} contentType - 'live' or 'vod'
 * @param {string} networkQuality - 'poor', 'good', or 'excellent'
 * @returns {string} The recommended streaming mode
 */
export function selectStreamingMode(contentType, networkQuality) {
  // VOD always uses quality mode for best viewing experience
  if (contentType === ContentType.VOD) {
    return StreamingMode.QUALITY;
  }

  // For live content, adapt based on network conditions
  switch (networkQuality) {
    case NetworkQuality.POOR:
      // Poor network: use low latency (smaller buffers = faster adaptation)
      return StreamingMode.LOW_LATENCY;
    case NetworkQuality.EXCELLENT:
      // Excellent network: can afford larger buffers for quality
      return StreamingMode.QUALITY;
    case NetworkQuality.GOOD:
    default:
      // Good network: balanced approach
      return StreamingMode.BALANCED;
  }
}

/**
 * Get the configuration for a specific streaming mode
 * @param {string} mode - The streaming mode
 * @returns {object} The configuration object with hls and mpegts settings
 */
export function getStreamingConfig(mode) {
  return StreamingProfiles[mode] || StreamingProfiles[StreamingMode.BALANCED];
}

/**
 * Merge user overrides with base configuration
 * @param {string} mode - The streaming mode
 * @param {object} overrides - User configuration overrides
 * @returns {object} Merged configuration
 */
export function mergeConfig(mode, overrides = {}) {
  const baseConfig = getStreamingConfig(mode);

  return {
    ...baseConfig,
    hls: { ...baseConfig.hls, ...overrides.hls },
    mpegts: { ...baseConfig.mpegts, ...overrides.mpegts },
  };
}

/**
 * Quality level presets for manual selection
 */
export const QualityLevels = {
  AUTO: -1,
  LOW: { maxHeight: 480, label: "480p" },
  MEDIUM: { maxHeight: 720, label: "720p" },
  HIGH: { maxHeight: 1080, label: "1080p" },
  ULTRA: { maxHeight: 2160, label: "4K" },
};

/**
 * Find the best matching quality level index from HLS levels
 * @param {Array} levels - HLS.js levels array
 * @param {number} targetHeight - Target resolution height
 * @returns {number} Level index or -1 for auto
 */
export function findQualityLevel(levels, targetHeight) {
  if (!levels || levels.length === 0 || targetHeight === -1) {
    return -1; // Auto
  }

  let bestMatch = -1;
  let closestDiff = Infinity;

  levels.forEach((level, index) => {
    const diff = Math.abs(level.height - targetHeight);
    if (diff < closestDiff && level.height <= targetHeight) {
      closestDiff = diff;
      bestMatch = index;
    }
  });

  // If no match found below target, use lowest available
  if (bestMatch === -1 && levels.length > 0) {
    bestMatch = 0;
  }

  return bestMatch;
}
