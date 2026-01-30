/**
 * Native Buffer Manager
 *
 * Intelligently monitors and optimizes browser's native video buffering for MP4/MKV streams.
 * Unlike HLS where we control buffer size, here we monitor and react to buffer health.
 *
 * Features:
 * - Buffer health monitoring
 * - Stall detection and recovery
 * - Preload optimization
 * - Network-aware behavior
 * - Bandwidth estimation
 */

import { bufferLogger as log } from "./logger";

// Buffer health states
const BufferHealth = {
  CRITICAL: "critical", // < 5s buffered, high stall risk
  LOW: "low", // 5-15s buffered
  GOOD: "good", // 15-45s buffered
  EXCELLENT: "excellent", // > 45s buffered
};

// Recovery strategies
const RecoveryStrategy = {
  NONE: "none",
  WAIT: "wait", // Just wait for buffer to fill
  REDUCE_QUALITY: "reduce_quality", // If quality options available
  PAUSE_PREFETCH: "pause_prefetch", // Pause to build buffer
};

/**
 * Native Buffer Manager for MP4/MKV streams
 */
export class NativeBufferManager {
  constructor(video, options = {}) {
    this.video = video;

    // Configuration
    this.config = {
      checkInterval: options.checkInterval || 2000, // Check every 2s
      minBufferForPlay: options.minBufferForPlay || 3, // Min 3s to start
      targetBuffer: options.targetBuffer || 30, // Target 30s buffer
      criticalBuffer: options.criticalBuffer || 5, // Critical below 5s
      lowBuffer: options.lowBuffer || 15, // Low below 15s
      stallThreshold: options.stallThreshold || 3, // Stalls before action
      recoveryPauseTime: options.recoveryPauseTime || 2000, // 2s pause to recover
      bandwidthSamples: options.bandwidthSamples || 10, // Samples for avg
    };

    // State
    this.isRunning = false;
    this.checkTimer = null;
    this.stallCount = 0;
    this.lastStallTime = 0;
    this.lastBufferedEnd = 0;
    this.lastCheckTime = 0;
    this.bandwidthHistory = [];
    this.isRecovering = false;
    this.totalStalls = 0;
    this.playbackStartTime = null;

    // Callbacks
    this.onBufferHealthChange = options.onBufferHealthChange || (() => {});
    this.onStall = options.onStall || (() => {});
    this.onRecovery = options.onRecovery || (() => {});
    this.onBandwidthUpdate = options.onBandwidthUpdate || (() => {});

    // Bind methods
    this._onWaiting = this._onWaiting.bind(this);
    this._onPlaying = this._onPlaying.bind(this);
    this._onProgress = this._onProgress.bind(this);
    this._onCanPlay = this._onCanPlay.bind(this);

    log.debug("[NativeBuffer] Initialized with config:", this.config);
  }

  /**
   * Start monitoring buffer health
   */
  start() {
    if (this.isRunning) return;
    this.isRunning = true;
    this.playbackStartTime = Date.now();

    // Listen to video events
    this.video.addEventListener("waiting", this._onWaiting);
    this.video.addEventListener("playing", this._onPlaying);
    this.video.addEventListener("progress", this._onProgress);
    this.video.addEventListener("canplay", this._onCanPlay);

    // Start periodic health check
    this.checkTimer = setInterval(() => this._checkHealth(), this.config.checkInterval);

    log.info("[NativeBuffer] Started monitoring");
  }

  /**
   * Stop monitoring
   */
  stop() {
    if (!this.isRunning) return;
    this.isRunning = false;

    // Remove listeners
    this.video.removeEventListener("waiting", this._onWaiting);
    this.video.removeEventListener("playing", this._onPlaying);
    this.video.removeEventListener("progress", this._onProgress);
    this.video.removeEventListener("canplay", this._onCanPlay);

    // Clear timer
    if (this.checkTimer) {
      clearInterval(this.checkTimer);
      this.checkTimer = null;
    }

    log.info("[NativeBuffer] Stopped monitoring. Stats:", this.getStats());
  }

  /**
   * Handle stall/buffering event
   */
  _onWaiting() {
    const now = Date.now();

    // Ignore stalls within 1s of each other (same event)
    if (now - this.lastStallTime < 1000) return;

    this.stallCount++;
    this.totalStalls++;
    this.lastStallTime = now;

    const bufferAhead = this.getBufferedAhead();
    log.warn(`[NativeBuffer] Stall #${this.totalStalls} (buffer: ${bufferAhead.toFixed(1)}s)`);

    this.onStall({
      stallCount: this.stallCount,
      totalStalls: this.totalStalls,
      bufferAhead,
    });

    // If too many stalls, try recovery
    if (this.stallCount >= this.config.stallThreshold && !this.isRecovering) {
      this._attemptRecovery();
    }
  }

  /**
   * Handle playback resumed
   */
  _onPlaying() {
    if (this.isRecovering) {
      this.isRecovering = false;
      log.info("[NativeBuffer] Recovery successful, playback resumed");
      this.onRecovery({ success: true });
    }

    // Reset stall count after 10s of smooth playback
    setTimeout(() => {
      if (!this.video.paused && !this.isRecovering) {
        this.stallCount = Math.max(0, this.stallCount - 1);
      }
    }, 10000);
  }

  /**
   * Handle progress event (buffer update)
   */
  _onProgress() {
    const now = Date.now();
    const bufferedEnd = this._getBufferedEnd();

    // Estimate bandwidth from buffer growth
    if (this.lastBufferedEnd > 0 && this.lastCheckTime > 0) {
      const timeDelta = (now - this.lastCheckTime) / 1000; // seconds
      const bufferGrowth = bufferedEnd - this.lastBufferedEnd; // seconds of video

      if (timeDelta > 0 && bufferGrowth > 0) {
        // Rough bandwidth estimate: video seconds downloaded / real seconds
        // Assuming ~5Mbps for 1080p, scale accordingly
        const downloadRatio = bufferGrowth / timeDelta;
        const estimatedBandwidth = downloadRatio * 5_000_000; // Very rough estimate

        this._recordBandwidth(estimatedBandwidth);
      }
    }

    this.lastBufferedEnd = bufferedEnd;
    this.lastCheckTime = now;
  }

  /**
   * Handle can play event
   */
  _onCanPlay() {
    const bufferAhead = this.getBufferedAhead();
    log.debug(`[NativeBuffer] Can play, buffer: ${bufferAhead.toFixed(1)}s`);
  }

  /**
   * Periodic health check
   */
  _checkHealth() {
    if (!this.video || this.video.paused) return;

    const bufferAhead = this.getBufferedAhead();
    const health = this.getBufferHealth();
    const avgBandwidth = this.getAverageBandwidth();

    log.debug(
      `[NativeBuffer] Health: ${health}, buffer: ${bufferAhead.toFixed(1)}s, bw: ${(avgBandwidth / 1_000_000).toFixed(2)}Mbps`
    );

    this.onBufferHealthChange({
      health,
      bufferAhead,
      bandwidth: avgBandwidth,
      stallCount: this.stallCount,
    });

    // Proactive recovery if buffer is critically low
    if (health === BufferHealth.CRITICAL && !this.isRecovering) {
      log.warn("[NativeBuffer] Critical buffer level detected");
      // Don't auto-pause, just log - browser handles this natively
    }
  }

  /**
   * Attempt to recover from repeated stalls
   */
  _attemptRecovery() {
    this.isRecovering = true;
    log.info("[NativeBuffer] Attempting recovery...");

    // Strategy: brief pause to build buffer
    const currentTime = this.video.currentTime;

    // Pause briefly to let buffer fill
    this.video.pause();

    setTimeout(() => {
      if (this.isRecovering) {
        const bufferNow = this.getBufferedAhead();
        log.info(`[NativeBuffer] Recovery pause done, buffer: ${bufferNow.toFixed(1)}s`);

        // Seek slightly forward to force fresh buffer fetch
        // This helps when stuck on a bad segment
        if (bufferNow < this.config.minBufferForPlay) {
          this.video.currentTime = currentTime + 0.5;
        }

        this.video.play().catch((e) => {
          log.warn("[NativeBuffer] Recovery play failed:", e.message);
        });

        this.stallCount = 0; // Reset after recovery attempt
      }
    }, this.config.recoveryPauseTime);

    this.onRecovery({ strategy: RecoveryStrategy.PAUSE_PREFETCH });
  }

  /**
   * Record bandwidth measurement
   */
  _recordBandwidth(bps) {
    this.bandwidthHistory.push({
      bps,
      time: Date.now(),
    });

    // Keep only recent samples
    if (this.bandwidthHistory.length > this.config.bandwidthSamples) {
      this.bandwidthHistory.shift();
    }

    this.onBandwidthUpdate(bps);
  }

  /**
   * Get buffered end time
   */
  _getBufferedEnd() {
    if (!this.video.buffered.length) return 0;

    const currentTime = this.video.currentTime;
    for (let i = 0; i < this.video.buffered.length; i++) {
      const start = this.video.buffered.start(i);
      const end = this.video.buffered.end(i);
      if (currentTime >= start && currentTime <= end) {
        return end;
      }
    }
    return 0;
  }

  /**
   * Get seconds buffered ahead of current time
   */
  getBufferedAhead() {
    if (!this.video || !this.video.buffered.length) return 0;

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
   * Get current buffer health state
   */
  getBufferHealth() {
    const buffered = this.getBufferedAhead();

    if (buffered < this.config.criticalBuffer) return BufferHealth.CRITICAL;
    if (buffered < this.config.lowBuffer) return BufferHealth.LOW;
    if (buffered < this.config.targetBuffer) return BufferHealth.GOOD;
    return BufferHealth.EXCELLENT;
  }

  /**
   * Get average bandwidth from recent measurements
   */
  getAverageBandwidth() {
    if (this.bandwidthHistory.length === 0) return 0;

    const now = Date.now();
    let weightedSum = 0;
    let weightSum = 0;

    this.bandwidthHistory.forEach((sample) => {
      const age = (now - sample.time) / 1000;
      const weight = Math.exp(-age / 30); // Decay over 30s
      weightedSum += sample.bps * weight;
      weightSum += weight;
    });

    return weightSum > 0 ? weightedSum / weightSum : 0;
  }

  /**
   * Get playback statistics
   */
  getStats() {
    const uptime = this.playbackStartTime ? (Date.now() - this.playbackStartTime) / 1000 : 0;

    return {
      totalStalls: this.totalStalls,
      stallsPerMinute: uptime > 0 ? (this.totalStalls / uptime) * 60 : 0,
      currentBuffer: this.getBufferedAhead(),
      bufferHealth: this.getBufferHealth(),
      averageBandwidth: this.getAverageBandwidth(),
      uptimeSeconds: uptime,
    };
  }

  /**
   * Get status for UI/debugging
   */
  getStatus() {
    return {
      isRunning: this.isRunning,
      bufferHealth: this.getBufferHealth(),
      bufferedAhead: this.getBufferedAhead(),
      stallCount: this.stallCount,
      totalStalls: this.totalStalls,
      isRecovering: this.isRecovering,
      averageBandwidth: this.getAverageBandwidth(),
    };
  }
}

export { BufferHealth, RecoveryStrategy };
export default NativeBufferManager;
