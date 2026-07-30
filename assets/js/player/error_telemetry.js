/**
 * Enhanced Error Telemetry
 *
 * Collects rich context when player errors occur.
 * Inspired by Netflix's approach to error diagnostics.
 *
 * Features:
 * - Captures device/browser info
 * - Records network conditions
 * - Includes codec detection results
 * - Tracks playback state at error time
 * - Aggregates errors for pattern detection
 */

import { getCapabilitySummary } from "../media/codec_detector";
import { getDeviceCompatibilityReport } from "./player_preferences";

// Error history for pattern detection
const errorHistory = [];
const MAX_ERROR_HISTORY = 50;

// Error categories for classification
const ErrorCategory = {
  NETWORK: "network",
  CODEC: "codec",
  DRM: "drm",
  MEDIA: "media",
  BUFFER: "buffer",
  UNKNOWN: "unknown",
};

// Error severity levels
const Severity = {
  LOW: "low", // Recoverable, minor impact
  MEDIUM: "medium", // May affect playback quality
  HIGH: "high", // Playback interrupted
  CRITICAL: "critical", // Playback failed completely
};

/**
 * Classify error into category
 */
function classifyError(error, context) {
  const errorString = String(error?.message || error || "").toLowerCase();
  const errorType = error?.type || context?.type || "";

  // Network errors
  if (
    errorString.includes("network") ||
    errorString.includes("fetch") ||
    errorString.includes("timeout") ||
    errorString.includes("connection") ||
    errorType.includes("network")
  ) {
    return ErrorCategory.NETWORK;
  }

  // Codec/format errors
  if (
    errorString.includes("codec") ||
    errorString.includes("decode") ||
    errorString.includes("format") ||
    errorString.includes("not supported") ||
    errorString.includes("media_err_decode")
  ) {
    return ErrorCategory.CODEC;
  }

  // DRM errors
  if (
    errorString.includes("drm") ||
    errorString.includes("key") ||
    errorString.includes("license") ||
    errorString.includes("encrypted")
  ) {
    return ErrorCategory.DRM;
  }

  // Buffer errors
  if (
    errorString.includes("buffer") ||
    errorString.includes("stall") ||
    errorString.includes("underrun")
  ) {
    return ErrorCategory.BUFFER;
  }

  // Media errors
  if (
    errorString.includes("media") ||
    errorString.includes("video") ||
    errorString.includes("audio") ||
    errorString.includes("playback")
  ) {
    return ErrorCategory.MEDIA;
  }

  return ErrorCategory.UNKNOWN;
}

/**
 * Determine error severity
 */
function determineSeverity(error, context) {
  const category = classifyError(error, context);

  // Critical: Complete playback failure
  if (context?.fatal || context?.playbackFailed) {
    return Severity.CRITICAL;
  }

  // High: Playback interrupted but may recover
  if (category === ErrorCategory.CODEC || category === ErrorCategory.DRM) {
    return Severity.HIGH;
  }

  // Medium: Quality may be affected
  if (category === ErrorCategory.NETWORK || category === ErrorCategory.BUFFER) {
    return Severity.MEDIUM;
  }

  // Low: Minor issue, likely recoverable
  return Severity.LOW;
}

/**
 * Get current network information
 */
function getNetworkInfo() {
  const connection = navigator.connection || navigator.mozConnection || navigator.webkitConnection;

  if (!connection) {
    return { available: false };
  }

  return {
    available: true,
    type: connection.type || "unknown",
    effectiveType: connection.effectiveType || "unknown",
    downlink: connection.downlink,
    rtt: connection.rtt,
    saveData: connection.saveData,
  };
}

/**
 * Get current playback state
 */
function getPlaybackState(videoElement, playerState = {}) {
  if (!videoElement) {
    return { available: false };
  }

  return {
    available: true,
    currentTime: videoElement.currentTime,
    duration: videoElement.duration,
    paused: videoElement.paused,
    ended: videoElement.ended,
    readyState: videoElement.readyState,
    networkState: videoElement.networkState,
    buffered: getBufferedRanges(videoElement),
    volume: videoElement.volume,
    muted: videoElement.muted,
    playbackRate: videoElement.playbackRate,
    videoWidth: videoElement.videoWidth,
    videoHeight: videoElement.videoHeight,
    // Player-specific state
    usingAVPlayer: playerState.usingAVPlayer || false,
    streamingMode: playerState.streamingMode || "unknown",
    streamType: playerState.streamType || "unknown",
    sourceType: playerState.sourceType || "unknown",
  };
}

/**
 * Get buffered time ranges
 */
function getBufferedRanges(videoElement) {
  if (!videoElement?.buffered) return [];

  const ranges = [];
  for (let i = 0; i < videoElement.buffered.length; i++) {
    ranges.push({
      start: videoElement.buffered.start(i),
      end: videoElement.buffered.end(i),
    });
  }
  return ranges;
}

/**
 * Get browser/device information
 */
function getDeviceInfo() {
  return {
    userAgent: navigator.userAgent,
    platform: navigator.platform,
    language: navigator.language,
    cookiesEnabled: navigator.cookieEnabled,
    memory: navigator.deviceMemory || "unknown",
    cores: navigator.hardwareConcurrency || "unknown",
    screenSize: `${screen.width}x${screen.height}`,
    windowSize: `${window.innerWidth}x${window.innerHeight}`,
    pixelRatio: window.devicePixelRatio,
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    online: navigator.onLine,
  };
}

/**
 * Create enriched error report
 */
export function createErrorReport(error, context = {}) {
  const category = classifyError(error, context);
  const severity = determineSeverity(error, context);

  const report = {
    // Error identification
    id: `err_${Date.now()}_${Math.random().toString(36).slice(2, 9)}`,
    timestamp: new Date().toISOString(),
    timestampMs: Date.now(),

    // Error details
    error: {
      message: error?.message || String(error),
      name: error?.name || "Error",
      stack: error?.stack?.slice(0, 1000), // Truncate stack trace
      code: error?.code,
      type: context?.type || error?.type,
    },

    // Classification
    category,
    severity,

    // Context
    context: {
      contentId: context.contentId,
      contentType: context.contentType,
      streamUrl: context.streamUrl ? maskUrl(context.streamUrl) : null,
      player: context.player || "unknown",
      action: context.action || "playback",
      retryCount: context.retryCount || 0,
      fallbackAttempt: context.fallbackAttempt || 0,
    },

    // State snapshots
    playback: getPlaybackState(context.videoElement, context.playerState),
    network: getNetworkInfo(),
    device: getDeviceInfo(),

    // Codec capabilities (cached for efficiency)
    codecs: getCapabilitySummary(),

    // Device compatibility history
    compatibility: getDeviceCompatibilityReport(),
  };

  // Add to history
  addToHistory(report);

  return report;
}

/**
 * Mask sensitive parts of URL (tokens, keys)
 */
function maskUrl(url) {
  try {
    const parsed = new URL(url);
    // Mask query parameters that might contain tokens
    const sensitiveParams = ["token", "key", "auth", "sig", "signature", "password"];
    for (const param of sensitiveParams) {
      if (parsed.searchParams.has(param)) {
        parsed.searchParams.set(param, "***");
      }
    }
    return parsed.toString();
  } catch {
    return url.replace(/token=[^&]+/gi, "token=***");
  }
}

/**
 * Add error to history for pattern detection
 */
function addToHistory(report) {
  errorHistory.push({
    id: report.id,
    timestamp: report.timestampMs,
    category: report.category,
    severity: report.severity,
    contentType: report.context.contentType,
  });

  // Trim history
  if (errorHistory.length > MAX_ERROR_HISTORY) {
    errorHistory.shift();
  }
}

/**
 * Detect error patterns (e.g., repeated failures)
 */
export function detectErrorPatterns() {
  const now = Date.now();
  const fiveMinutes = 5 * 60 * 1000;
  const recentErrors = errorHistory.filter((e) => now - e.timestamp < fiveMinutes);

  const patterns = {
    repeatedCategory: null,
    errorBurst: false,
    recommendations: [],
  };

  // Check for repeated errors of same category
  const categoryCounts = {};
  for (const error of recentErrors) {
    categoryCounts[error.category] = (categoryCounts[error.category] || 0) + 1;
  }

  for (const [category, count] of Object.entries(categoryCounts)) {
    if (count >= 3) {
      patterns.repeatedCategory = category;
      patterns.recommendations.push(getRecommendation(category));
    }
  }

  // Check for error burst (many errors in short time)
  if (recentErrors.length >= 5) {
    const lastFive = recentErrors.slice(-5);
    const timeSpan = lastFive[4].timestamp - lastFive[0].timestamp;
    if (timeSpan < 30000) {
      // 5 errors in 30 seconds
      patterns.errorBurst = true;
      patterns.recommendations.push("Consider pausing playback and retrying later");
    }
  }

  return patterns;
}

/**
 * Get recommendation based on error category
 */
function getRecommendation(category) {
  const recommendations = {
    [ErrorCategory.NETWORK]: "Check your internet connection or try a lower quality",
    [ErrorCategory.CODEC]:
      "This content may require a different player. Try enabling Audio Compatibility mode",
    [ErrorCategory.DRM]: "This content is protected. Make sure you have the necessary permissions",
    [ErrorCategory.BUFFER]:
      "Buffering issues detected. Try reducing video quality or check your connection",
    [ErrorCategory.MEDIA]: "Media playback issue. Try refreshing the page",
    [ErrorCategory.UNKNOWN]: "An unexpected error occurred. Please try again",
  };

  return recommendations[category] || recommendations[ErrorCategory.UNKNOWN];
}

/**
 * Get error statistics for diagnostics
 */
export function getErrorStatistics() {
  const now = Date.now();
  const oneHour = 60 * 60 * 1000;
  const recentErrors = errorHistory.filter((e) => now - e.timestamp < oneHour);

  const stats = {
    totalErrors: errorHistory.length,
    lastHourErrors: recentErrors.length,
    byCategory: {},
    bySeverity: {},
    patterns: detectErrorPatterns(),
  };

  for (const error of recentErrors) {
    stats.byCategory[error.category] = (stats.byCategory[error.category] || 0) + 1;
    stats.bySeverity[error.severity] = (stats.bySeverity[error.severity] || 0) + 1;
  }

  return stats;
}

/**
 * Clear error history
 */
export function clearErrorHistory() {
  errorHistory.length = 0;
}

/**
 * Format error report for logging
 */
export function formatErrorForLog(report) {
  return `[${report.severity.toUpperCase()}] ${report.category}: ${report.error.message} (${report.context.player}, ${report.context.contentType})`;
}

export default {
  createErrorReport,
  detectErrorPatterns,
  getErrorStatistics,
  clearErrorHistory,
  formatErrorForLog,
  ErrorCategory,
  Severity,
};
