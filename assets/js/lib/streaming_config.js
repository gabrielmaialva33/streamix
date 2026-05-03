/**
 * Streaming Configuration Profiles for Streamix
 *
 * Four optimized profiles for different use cases:
 * - low_latency: Live sports/events (2-5s delay)
 * - balanced: Regular live TV (10-15s delay)
 * - quality: VOD content (maximum quality, larger buffers)
 * - adaptive: Intelligent adaptive buffering
 *
 * v2: Enhanced with buffer stall prevention, progressive loading,
 *     mobile optimization, and live edge catchup.
 */

export const StreamingMode = {
  LOW_LATENCY: "low_latency",
  BALANCED: "balanced",
  QUALITY: "quality",
  ADAPTIVE: "adaptive",
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

// Shared settings that prevent buffer stalls across all profiles
const sharedStallPrevention = {
  maxFragLookUpTolerance: 0.1, // Smooth seeking
  highBufferWatchdogPeriod: 2, // Check buffer health every 2s
  nudgeMaxRetry: 5, // Retry nudging on stall
  nudgeOnVideoHole: true, // Seek past holes in video buffer
  maxStarvationDelay: 2, // Max 2s rebuffer before ABR drops quality (default 4s)
  maxLoadingDelay: 3, // Max loading delay for start level selection
  startLevel: -1, // Auto quality
  enableWorker: true,
  progressive: true, // Progressive loading for smoother start
  capLevelToPlayerSize: true, // Don't waste bandwidth on resolutions larger than player
};

/**
 * Streaming configuration profiles for HLS.js and mpegts.js
 */
const StreamingProfiles = {
  [StreamingMode.LOW_LATENCY]: {
    name: "Low Latency",
    description: "Optimized for live events with minimal delay",
    hls: {
      ...sharedStallPrevention,
      // For tiny LL-HLS parts, worker hop overhead can hurt more than it helps.
      enableWorker: false,
      lowLatencyMode: true,
      maxBufferLength: 15,
      maxBufferSize: 20 * 1000 * 1000, // 20MB
      maxMaxBufferLength: 20,
      backBufferLength: 2,
      liveSyncDuration: 1.4,
      liveMaxLatencyDuration: 5,
      liveSyncOnStallIncrease: 0.2,
      maxLiveSyncPlaybackRate: 1.2, // Gentle catch-up to stay close to live edge
      // ABR settings - faster adaptation
      abrBandWidthFactor: 0.9,
      abrBandWidthUpFactor: 0.7,
      abrEwmaDefaultEstimate: 500000,
      // Fragment loading - shorter timeouts for live
      fragLoadingTimeOut: 10000,
      fragLoadingMaxRetry: 3,
      fragLoadingRetryDelay: 500,
      fragLoadingMaxRetryDelay: 4000, // Cap retry delay
      // Level loading
      levelLoadingTimeOut: 8000,
      levelLoadingMaxRetry: 3,
      // Buffer holes
      maxBufferHole: 0.3,
    },
    mpegts: {
      enableWorker: true,
      enableStashBuffer: true,
      stashInitialSize: 256 * 1024,
      autoCleanupSourceBuffer: true,
      autoCleanupMaxBackwardDuration: 30,
      autoCleanupMinBackwardDuration: 15,
      liveBufferLatencyChasing: true,
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
      ...sharedStallPrevention,
      lowLatencyMode: false,
      maxBufferLength: 60,
      maxBufferSize: 60 * 1000 * 1000, // 60MB
      maxMaxBufferLength: 120,
      backBufferLength: 60,
      frontBufferFlushThreshold: 300, // Flush forward buffer after 5min to save memory
      liveSyncDurationCount: 3,
      maxLiveSyncPlaybackRate: 1.3, // Moderate catchup for live
      // ABR settings - balanced
      abrBandWidthFactor: 0.85,
      abrBandWidthUpFactor: 0.6,
      abrEwmaDefaultEstimate: 500000,
      // Fragment loading
      fragLoadingTimeOut: 15000,
      fragLoadingMaxRetry: 4,
      fragLoadingRetryDelay: 1000,
      fragLoadingMaxRetryDelay: 8000,
      // Level loading
      levelLoadingTimeOut: 10000,
      levelLoadingMaxRetry: 4,
      // Buffer holes
      maxBufferHole: 0.5,
    },
    mpegts: {
      enableWorker: true,
      enableStashBuffer: true,
      stashInitialSize: 384 * 1024,
      autoCleanupSourceBuffer: true,
      autoCleanupMaxBackwardDuration: 45,
      autoCleanupMinBackwardDuration: 30,
      liveBufferLatencyChasing: false,
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
      ...sharedStallPrevention,
      lowLatencyMode: false,
      maxBufferLength: 90,
      maxBufferSize: 90 * 1000 * 1000, // 90MB
      maxMaxBufferLength: 180,
      backBufferLength: 180,
      frontBufferFlushThreshold: 600, // Flush forward buffer after 10min
      // ABR settings - conservative, prefer quality
      abrBandWidthFactor: 0.8,
      abrBandWidthUpFactor: 0.5,
      abrEwmaDefaultEstimate: 500000,
      // Fragment loading - longer timeouts, more retries
      fragLoadingTimeOut: 20000,
      fragLoadingMaxRetry: 6,
      fragLoadingRetryDelay: 1000,
      fragLoadingMaxRetryDelay: 12000,
      // Level loading
      levelLoadingTimeOut: 10000,
      levelLoadingMaxRetry: 4,
      levelLoadingRetryDelay: 1000,
      // Buffer holes
      maxBufferHole: 0.5,
    },
    mpegts: {
      enableWorker: true,
      enableStashBuffer: true,
      stashInitialSize: 512 * 1024,
      autoCleanupSourceBuffer: true,
      autoCleanupMaxBackwardDuration: 60,
      autoCleanupMinBackwardDuration: 30,
      liveBufferLatencyChasing: false,
      lazyLoad: true,
      lazyLoadMaxDuration: 60,
      lazyLoadRecoverDuration: 30,
      accurateSeek: true,
      seekType: "range",
    },
  },

  [StreamingMode.ADAPTIVE]: {
    name: "Adaptive",
    description: "Intelligent buffering: fast start, adapts to network conditions",
    hls: {
      ...sharedStallPrevention,
      lowLatencyMode: false,
      maxBufferLength: 30,
      maxBufferSize: 40 * 1000 * 1000, // 40MB
      maxMaxBufferLength: 60,
      backBufferLength: 30,
      frontBufferFlushThreshold: 300,
      maxLiveSyncPlaybackRate: 1.3,
      // ABR settings - responsive but stable
      abrBandWidthFactor: 0.85,
      abrBandWidthUpFactor: 0.6,
      abrEwmaDefaultEstimate: 1000000, // 1Mbps default
      abrEwmaFastLive: 3.0,
      abrEwmaSlowLive: 9.0,
      // Fragment loading
      fragLoadingTimeOut: 15000,
      fragLoadingMaxRetry: 4,
      fragLoadingRetryDelay: 1000,
      fragLoadingMaxRetryDelay: 8000,
      // Level loading
      levelLoadingTimeOut: 10000,
      levelLoadingMaxRetry: 4,
      levelLoadingRetryDelay: 500,
      // Buffer holes
      maxBufferHole: 0.3,

      // Adaptive-specific: used by AdaptiveBufferManager
      _adaptive: {
        minBuffer: 15,
        maxBuffer: 60,
        targetBuffer: 30,
        stallThreshold: 3,
        goodNetworkThreshold: 2000000, // 2Mbps
        bufferGrowthRate: 5,
        bufferShrinkRate: 10,
      },
    },
    mpegts: {
      enableWorker: true,
      enableStashBuffer: true,
      stashInitialSize: 384 * 1024,
      autoCleanupSourceBuffer: true,
      autoCleanupMaxBackwardDuration: 45,
      autoCleanupMinBackwardDuration: 20,
      liveBufferLatencyChasing: false,
      lazyLoad: true,
      lazyLoadMaxDuration: 45,
      lazyLoadRecoverDuration: 20,
      accurateSeek: true,
      seekType: "range",
    },
  },
};

/**
 * Select the optimal streaming mode based on content type and network quality
 */
export function selectStreamingMode(contentType, networkQuality) {
  if (contentType === ContentType.VOD) {
    return StreamingMode.QUALITY;
  }

  switch (networkQuality) {
    case NetworkQuality.POOR:
      return StreamingMode.LOW_LATENCY;
    case NetworkQuality.EXCELLENT:
      return StreamingMode.QUALITY;
    default:
      return StreamingMode.BALANCED;
  }
}

/**
 * Get the configuration for a specific streaming mode
 */
export function getStreamingConfig(mode) {
  return StreamingProfiles[mode] || StreamingProfiles[StreamingMode.BALANCED];
}





/**
 * Advanced feature flags for experimental APIs
 */
export const FeatureFlags = {
  webCodecs: {
    enabled: true,
    preferHardwareAcceleration: true,
    fallbackToSoftware: true,
  },
  mseWorkers: {
    enabled: true,
    offloadParsing: true,
    useTransferables: true,
  },
  codecPriority: {
    enabled: true,
    preferEfficient: true,
    adaptToNetwork: true,
    adaptToDevice: true,
  },
  advancedABR: {
    enabled: true,
    useCodecEfficiency: true,
    bandwidthEstimation: "ewma",
    safetyFactor: 0.8,
  },
};


/**
 * Determine if experimental features should be used
 */
export function getFeatureRecommendations(capabilities) {
  const recommendations = {
    useWebCodecs: false,
    useMSEWorkers: false,
    preferAV1: false,
    preferHEVC: false,
  };

  if (capabilities?.webcodecs?.supported && FeatureFlags.webCodecs.enabled) {
    recommendations.useWebCodecs = true;
  }

  if (capabilities?.mseWorkers?.supported && FeatureFlags.mseWorkers.enabled) {
    recommendations.useMSEWorkers = true;
  }

  if (capabilities?.video?.av1?.supported && FeatureFlags.codecPriority.preferEfficient) {
    recommendations.preferAV1 = true;
  } else if (capabilities?.video?.hevc?.supported && FeatureFlags.codecPriority.preferEfficient) {
    recommendations.preferHEVC = true;
  }

  return recommendations;
}
