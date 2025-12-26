/**
 * Network Monitor for Streamix
 *
 * Monitors network conditions and provides bandwidth estimates
 * to enable adaptive streaming mode selection.
 */

import { NetworkQuality } from "./streaming_config";

// Bandwidth thresholds in bits per second
const BANDWIDTH_THRESHOLDS = {
  POOR: 1000000, // 1 Mbps
  GOOD: 5000000, // 5 Mbps
};

// Number of samples to keep for averaging
const MAX_SAMPLES = 10;

// Minimum samples before making quality decisions
const MIN_SAMPLES = 3;

/**
 * NetworkMonitor class for tracking bandwidth and connection quality
 */
export class NetworkMonitor {
  constructor(options = {}) {
    this.samples = [];
    this.currentQuality = NetworkQuality.GOOD;
    this.onQualityChange = options.onQualityChange || null;
    this.intervalId = null;

    // Configuration
    this.maxSamples = options.maxSamples || MAX_SAMPLES;
    this.minSamples = options.minSamples || MIN_SAMPLES;
    this.checkInterval = options.checkInterval || 5000; // 5 seconds

    // Use Navigator API if available
    this.useNavigatorAPI = "connection" in navigator;
  }

  /**
   * Start monitoring network conditions
   */
  start() {
    // Initial check using Navigator API
    if (this.useNavigatorAPI) {
      this.checkNavigatorConnection();
      navigator.connection?.addEventListener("change", () => {
        this.checkNavigatorConnection();
      });
    }

    // Periodic check
    this.intervalId = setInterval(() => {
      this.evaluateQuality();
    }, this.checkInterval);
  }

  /**
   * Stop monitoring
   */
  stop() {
    if (this.intervalId) {
      clearInterval(this.intervalId);
      this.intervalId = null;
    }
  }

  /**
   * Check connection using Navigator Network Information API
   */
  checkNavigatorConnection() {
    if (!navigator.connection) return;

    const connection = navigator.connection;
    const effectiveType = connection.effectiveType;
    const downlink = connection.downlink; // Mbps

    // Map effective type to our quality levels
    let estimatedQuality;
    switch (effectiveType) {
      case "slow-2g":
      case "2g":
        estimatedQuality = NetworkQuality.POOR;
        break;
      case "3g":
        estimatedQuality = NetworkQuality.GOOD;
        break;
      case "4g":
      default:
        estimatedQuality =
          downlink > 5 ? NetworkQuality.EXCELLENT : NetworkQuality.GOOD;
    }

    // Add to samples as bps for consistency
    if (downlink) {
      this.addSample(downlink * 1000000);
    }
  }

  /**
   * Add a bandwidth sample (from HLS.js or mpegts.js)
   * @param {number} bandwidth - Bandwidth in bits per second
   */
  addSample(bandwidth) {
    if (!bandwidth || bandwidth <= 0) return;

    this.samples.push({
      bandwidth,
      timestamp: Date.now(),
    });

    // Keep only recent samples
    if (this.samples.length > this.maxSamples) {
      this.samples.shift();
    }

    // Evaluate quality if we have enough samples
    if (this.samples.length >= this.minSamples) {
      this.evaluateQuality();
    }
  }

  /**
   * Calculate average bandwidth from recent samples
   * @returns {number} Average bandwidth in bps
   */
  getAverageBandwidth() {
    if (this.samples.length === 0) return 0;

    const sum = this.samples.reduce((acc, s) => acc + s.bandwidth, 0);
    return sum / this.samples.length;
  }

  /**
   * Calculate weighted average (recent samples have more weight)
   * @returns {number} Weighted average bandwidth in bps
   */
  getWeightedAverageBandwidth() {
    if (this.samples.length === 0) return 0;

    let weightedSum = 0;
    let totalWeight = 0;

    this.samples.forEach((sample, index) => {
      // Weight increases with recency
      const weight = index + 1;
      weightedSum += sample.bandwidth * weight;
      totalWeight += weight;
    });

    return weightedSum / totalWeight;
  }

  /**
   * Evaluate current network quality based on samples
   */
  evaluateQuality() {
    if (this.samples.length < this.minSamples) return;

    const avgBandwidth = this.getWeightedAverageBandwidth();
    const previousQuality = this.currentQuality;

    // Determine quality with hysteresis to prevent oscillation
    if (avgBandwidth < BANDWIDTH_THRESHOLDS.POOR * 0.8) {
      this.currentQuality = NetworkQuality.POOR;
    } else if (avgBandwidth < BANDWIDTH_THRESHOLDS.POOR * 1.2) {
      // Hysteresis zone - keep current if already poor
      if (previousQuality !== NetworkQuality.POOR) {
        this.currentQuality = NetworkQuality.GOOD;
      }
    } else if (avgBandwidth < BANDWIDTH_THRESHOLDS.GOOD * 0.8) {
      this.currentQuality = NetworkQuality.GOOD;
    } else if (avgBandwidth < BANDWIDTH_THRESHOLDS.GOOD * 1.2) {
      // Hysteresis zone - keep current unless clearly excellent
      if (previousQuality === NetworkQuality.EXCELLENT) {
        this.currentQuality = NetworkQuality.EXCELLENT;
      } else {
        this.currentQuality = NetworkQuality.GOOD;
      }
    } else {
      this.currentQuality = NetworkQuality.EXCELLENT;
    }

    // Notify if quality changed
    if (previousQuality !== this.currentQuality && this.onQualityChange) {
      this.onQualityChange(this.currentQuality, previousQuality, {
        bandwidth: avgBandwidth,
        samples: this.samples.length,
      });
    }
  }

  /**
   * Get current network quality
   * @returns {string} Current quality level
   */
  getQuality() {
    return this.currentQuality;
  }

  /**
   * Get current statistics
   * @returns {object} Network statistics
   */
  getStats() {
    return {
      quality: this.currentQuality,
      averageBandwidth: this.getAverageBandwidth(),
      weightedBandwidth: this.getWeightedAverageBandwidth(),
      samples: this.samples.length,
      lastSample: this.samples[this.samples.length - 1] || null,
    };
  }

  /**
   * Reset all samples and quality
   */
  reset() {
    this.samples = [];
    this.currentQuality = NetworkQuality.GOOD;
  }

  /**
   * Format bandwidth for display
   * @param {number} bps - Bandwidth in bits per second
   * @returns {string} Formatted string (e.g., "5.2 Mbps")
   */
  static formatBandwidth(bps) {
    if (bps >= 1000000) {
      return `${(bps / 1000000).toFixed(1)} Mbps`;
    } else if (bps >= 1000) {
      return `${(bps / 1000).toFixed(0)} Kbps`;
    }
    return `${bps} bps`;
  }
}

/**
 * Create a network monitor instance with default settings
 * @param {object} options - Configuration options
 * @returns {NetworkMonitor} Network monitor instance
 */
export function createNetworkMonitor(options = {}) {
  return new NetworkMonitor(options);
}

/**
 * Detect buffer health based on video element state
 * @param {HTMLVideoElement} video - Video element
 * @param {number} threshold - Buffer threshold in seconds
 * @returns {object} Buffer health status
 */
export function getBufferHealth(video, threshold = 5) {
  if (!video || !video.buffered || video.buffered.length === 0) {
    return { status: "unknown", ahead: 0, behind: 0 };
  }

  const currentTime = video.currentTime;
  let bufferAhead = 0;
  let bufferBehind = 0;

  // Find the buffer range containing current time
  for (let i = 0; i < video.buffered.length; i++) {
    const start = video.buffered.start(i);
    const end = video.buffered.end(i);

    if (currentTime >= start && currentTime <= end) {
      bufferAhead = end - currentTime;
      bufferBehind = currentTime - start;
      break;
    }
  }

  let status;
  if (bufferAhead < threshold * 0.3) {
    status = "critical";
  } else if (bufferAhead < threshold * 0.6) {
    status = "warning";
  } else {
    status = "good";
  }

  return {
    status,
    ahead: bufferAhead,
    behind: bufferBehind,
    total: bufferAhead + bufferBehind,
  };
}

export default NetworkMonitor;
