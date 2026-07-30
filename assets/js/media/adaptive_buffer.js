/**
 * Adaptive Buffer Manager
 *
 * Intelligently adjusts HLS.js buffer settings based on:
 * - Network bandwidth measurements
 * - Stall/rebuffer events
 * - Buffer health
 * - Playback stability
 *
 * Goals:
 * - Fast playback start (smaller initial buffer)
 * - No stalls during playback (grow buffer if network is good)
 * - Responsive to network changes (shrink buffer on poor network)
 */

// Need to import Hls for events
import Hls from "hls.js";
import { streamLogger as log } from "../core/logger";

// Buffer health states
const BufferHealth = {
  CRITICAL: "critical", // < 5s buffered, risk of stall
  LOW: "low", // 5-15s buffered
  GOOD: "good", // 15-30s buffered
  EXCELLENT: "excellent", // > 30s buffered
};

// Network quality based on bandwidth
const NetworkQuality = {
  POOR: "poor", // < 500Kbps
  FAIR: "fair", // 500Kbps - 2Mbps
  GOOD: "good", // 2-5Mbps
  EXCELLENT: "excellent", // > 5Mbps
};

/**
 * Adaptive Buffer Manager
 */
export class AdaptiveBufferManager {
  constructor(hls, options = {}) {
    this.hls = hls;
    this.video = hls.media;

    // Configuration
    this.config = {
      minBuffer: options.minBuffer || 15,
      maxBuffer: options.maxBuffer || 60,
      targetBuffer: options.targetBuffer || 30,
      stallThreshold: options.stallThreshold || 3,
      goodNetworkThreshold: options.goodNetworkThreshold || 2000000, // 2Mbps
      bufferGrowthRate: options.bufferGrowthRate || 5,
      bufferShrinkRate: options.bufferShrinkRate || 10,
      checkInterval: options.checkInterval || 5000, // Check every 5s
    };

    // State
    this.stallCount = 0;
    this.lastStallTime = 0;
    this.bandwidthHistory = [];
    this.currentBufferTarget = this.config.targetBuffer;
    this.isRunning = false;
    this.checkTimer = null;

    // Bind methods
    this.onWaiting = this.onWaiting.bind(this);
    this.onPlaying = this.onPlaying.bind(this);
    this.onFragLoaded = this.onFragLoaded.bind(this);

    log.debug("[AdaptiveBuffer] Initialized with config:", this.config);
  }

  /**
   * Start monitoring and adjusting buffers
   */
  start() {
    if (this.isRunning) return;
    this.isRunning = true;

    // Listen to video events
    if (this.video) {
      this.video.addEventListener("waiting", this.onWaiting);
      this.video.addEventListener("playing", this.onPlaying);
    }

    // Listen to HLS events
    if (this.hls) {
      this.hls.on(Hls.Events.FRAG_LOADED, this.onFragLoaded);
    }

    // Start periodic buffer health check
    this.checkTimer = setInterval(() => this.checkAndAdjust(), this.config.checkInterval);

    log.debug("[AdaptiveBuffer] Started monitoring");
  }

  /**
   * Stop monitoring
   */
  stop() {
    this.isRunning = false;

    if (this.video) {
      this.video.removeEventListener("waiting", this.onWaiting);
      this.video.removeEventListener("playing", this.onPlaying);
    }

    if (this.checkTimer) {
      clearInterval(this.checkTimer);
      this.checkTimer = null;
    }

    log.debug("[AdaptiveBuffer] Stopped monitoring");
  }

  /**
   * Handle stall/buffering event
   */
  onWaiting() {
    const now = Date.now();

    // Ignore stalls within 2s of each other (same event)
    if (now - this.lastStallTime < 2000) return;

    this.stallCount++;
    this.lastStallTime = now;

    log.warn(`[AdaptiveBuffer] Stall detected (#${this.stallCount})`);

    // If too many stalls, reduce buffer aggressively
    if (this.stallCount >= this.config.stallThreshold) {
      this.reduceBuffer("frequent stalls");
      this.stallCount = 0; // Reset after action
    }
  }

  /**
   * Handle playback resumed
   */
  onPlaying() {
    // Reset stall count after successful playback for 10s
    setTimeout(() => {
      if (!this.video?.paused) {
        this.stallCount = Math.max(0, this.stallCount - 1);
      }
    }, 10000);
  }

  /**
   * Track bandwidth from fragment loads
   */
  onFragLoaded(_event, data) {
    if (data?.frag?.stats?.loaded && data?.frag?.stats?.loading?.end) {
      const loadTime = data.frag.stats.loading.end - data.frag.stats.loading.start;
      if (loadTime > 0) {
        const bandwidth = (data.frag.stats.loaded * 8000) / loadTime;
        this.recordBandwidth(bandwidth);
      }
    }
  }

  /**
   * Record bandwidth measurement
   */
  recordBandwidth(bps) {
    this.bandwidthHistory.push({
      bps,
      time: Date.now(),
    });

    // Keep only last 30 measurements
    if (this.bandwidthHistory.length > 30) {
      this.bandwidthHistory.shift();
    }
  }

  /**
   * Get average bandwidth from recent measurements
   */
  getAverageBandwidth() {
    if (this.bandwidthHistory.length === 0) return 0;

    // Weight recent measurements more heavily
    const now = Date.now();
    let weightedSum = 0;
    let weightSum = 0;

    this.bandwidthHistory.forEach((measurement) => {
      const age = (now - measurement.time) / 1000; // seconds
      const weight = Math.exp(-age / 30); // Exponential decay over 30s
      weightedSum += measurement.bps * weight;
      weightSum += weight;
    });

    return weightSum > 0 ? weightedSum / weightSum : 0;
  }

  /**
   * Get current network quality
   */
  getNetworkQuality() {
    const bw = this.getAverageBandwidth();

    if (bw < 500000) return NetworkQuality.POOR;
    if (bw < 2000000) return NetworkQuality.FAIR;
    if (bw < 5000000) return NetworkQuality.GOOD;
    return NetworkQuality.EXCELLENT;
  }

  /**
   * Get current buffer health
   */
  getBufferHealth() {
    if (!this.video) return BufferHealth.CRITICAL;

    const buffered = this.getBufferedAhead();

    if (buffered < 5) return BufferHealth.CRITICAL;
    if (buffered < 15) return BufferHealth.LOW;
    if (buffered < 30) return BufferHealth.GOOD;
    return BufferHealth.EXCELLENT;
  }

  /**
   * Get seconds buffered ahead of current time
   */
  getBufferedAhead() {
    if (!this.video?.buffered.length) return 0;

    const currentTime = this.video.currentTime;
    let bufferedAhead = 0;

    for (let i = 0; i < this.video.buffered.length; i++) {
      const start = this.video.buffered.start(i);
      const end = this.video.buffered.end(i);

      if (currentTime >= start && currentTime <= end) {
        bufferedAhead = end - currentTime;
        break;
      }
    }

    return bufferedAhead;
  }

  /**
   * Periodic check and adjust buffer settings
   */
  checkAndAdjust() {
    if (!this.hls || !this.video) return;

    const bufferHealth = this.getBufferHealth();
    const networkQuality = this.getNetworkQuality();
    const bandwidth = this.getAverageBandwidth();

    log.debug(
      `[AdaptiveBuffer] Check: buffer=${bufferHealth}, network=${networkQuality}, bw=${(bandwidth / 1000000).toFixed(2)}Mbps, target=${this.currentBufferTarget}s`,
    );

    // Decision logic
    if (bufferHealth === BufferHealth.CRITICAL) {
      // Emergency: buffer very low, don't change settings (let it recover)
      log.warn("[AdaptiveBuffer] Critical buffer level, waiting for recovery");
      return;
    }

    if (networkQuality === NetworkQuality.EXCELLENT && bufferHealth === BufferHealth.EXCELLENT) {
      // Great conditions: can grow buffer for smoother playback
      this.growBuffer("excellent network and buffer");
    } else if (
      networkQuality === NetworkQuality.POOR ||
      (bufferHealth === BufferHealth.LOW && this.stallCount > 0)
    ) {
      // Poor conditions: reduce buffer for faster adaptation
      this.reduceBuffer("poor network or low buffer with stalls");
    }
    // Otherwise, maintain current settings
  }

  /**
   * Increase buffer size
   */
  growBuffer(reason) {
    const newTarget = Math.min(
      this.currentBufferTarget + this.config.bufferGrowthRate,
      this.config.maxBuffer,
    );

    if (newTarget > this.currentBufferTarget) {
      this.currentBufferTarget = newTarget;
      this.applyBufferSettings();
      log.info(`[AdaptiveBuffer] Growing buffer to ${newTarget}s (${reason})`);
    }
  }

  /**
   * Reduce buffer size
   */
  reduceBuffer(reason) {
    const newTarget = Math.max(
      this.currentBufferTarget - this.config.bufferShrinkRate,
      this.config.minBuffer,
    );

    if (newTarget < this.currentBufferTarget) {
      this.currentBufferTarget = newTarget;
      this.applyBufferSettings();
      log.info(`[AdaptiveBuffer] Reducing buffer to ${newTarget}s (${reason})`);
    }
  }

  /**
   * Apply current buffer settings to HLS.js
   */
  applyBufferSettings() {
    if (!this.hls) return;

    // Update HLS.js config
    this.hls.config.maxBufferLength = this.currentBufferTarget;
    this.hls.config.maxMaxBufferLength = this.currentBufferTarget * 2;
    this.hls.config.maxBufferSize = this.currentBufferTarget * 1000 * 1000; // ~1MB per second

    log.debug(`[AdaptiveBuffer] Applied settings: maxBufferLength=${this.currentBufferTarget}s`);
  }

  /**
   * Get current status for UI/debugging
   */
  getStatus() {
    return {
      bufferHealth: this.getBufferHealth(),
      networkQuality: this.getNetworkQuality(),
      averageBandwidth: this.getAverageBandwidth(),
      bufferedAhead: this.getBufferedAhead(),
      currentBufferTarget: this.currentBufferTarget,
      stallCount: this.stallCount,
      isRunning: this.isRunning,
    };
  }
}

export default AdaptiveBufferManager;
