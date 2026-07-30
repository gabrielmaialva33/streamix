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

import { bufferLogger as log } from "../core/logger";

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
      startupGraceMs: options.startupGraceMs || 5000, // Ignore startup/resume jitter
      seekGraceMs: options.seekGraceMs || 3000, // Ignore expected buffering after timeline jumps
      stallLogCooldownMs: options.stallLogCooldownMs || 10000,
      criticalLogCooldownMs: options.criticalLogCooldownMs || 15000,
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
    this.lastSeekTime = 0;
    this.lastStallWarningTime = 0;
    this.lastCriticalWarningTime = 0;

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
    this._onSeeking = this._onSeeking.bind(this);

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
    this.video.addEventListener("seeking", this._onSeeking);

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
    this.video.removeEventListener("seeking", this._onSeeking);

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

    // Ignore "waiting" events during timeline jumps. Some browsers flip
    // video.seeking back to false before the new range has enough bytes.
    if (this.video?.seeking || this._isInSeekGrace(now)) {
      log.debug("Ignoring waiting event during seek");
      return;
    }

    this.stallCount++;
    this.totalStalls++;
    this.lastStallTime = now;

    const bufferAhead = this.getBufferedAhead();
    const readyState = this.video?.readyState || 0;
    const isStartupGrace = this._isInStartupGrace(now);
    const isRealStall = readyState < 3 && !this.video.paused && !isStartupGrace;
    const shouldRecover =
      this.stallCount >= this.config.stallThreshold && !this.isRecovering && isRealStall;

    if (shouldRecover && now - this.lastStallWarningTime >= this.config.stallLogCooldownMs) {
      this.lastStallWarningTime = now;
      log.warn(
        `Stall #${this.totalStalls} (buffer: ${bufferAhead.toFixed(1)}s, ready: ${readyState})`,
      );
    } else {
      log.debug(
        `Brief pause #${this.totalStalls} (buffer: ${bufferAhead.toFixed(1)}s, ready: ${readyState})`,
      );
    }

    this.onStall({
      stallCount: this.stallCount,
      totalStalls: this.totalStalls,
      bufferAhead,
      readyState,
      isRealStall,
      isStartupGrace,
      shouldRecover,
    });

    // Only attempt recovery for real stalls (low readyState + multiple occurrences)
    if (shouldRecover) {
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

  _onSeeking() {
    this.lastSeekTime = Date.now();
    this.stallCount = 0;
  }

  /**
   * Periodic health check
   */
  _checkHealth() {
    if (!this.video) return;

    const bufferAhead = this.getBufferedAhead();
    const health = this.getBufferHealth();
    const avgBandwidth = this.getAverageBandwidth();
    const readyState = this.video.readyState;
    const networkState = this.video.networkState;

    // Only log if playing or has meaningful buffer
    if (!this.video.paused || bufferAhead > 0) {
      log.debug(
        `Health: ${health}, buffer: ${bufferAhead.toFixed(1)}s, ready: ${readyState}, network: ${networkState}`,
      );
    }

    this.onBufferHealthChange({
      health,
      bufferAhead,
      bandwidth: avgBandwidth,
      stallCount: this.stallCount,
      readyState,
      networkState,
    });

    // Proactive recovery if buffer is critically low and video is trying to play
    if (
      health === BufferHealth.CRITICAL &&
      !this.isRecovering &&
      !this.video.paused &&
      !this._isInStartupGrace() &&
      !this._isInSeekGrace() &&
      readyState < 3
    ) {
      const now = Date.now();
      if (now - this.lastCriticalWarningTime < this.config.criticalLogCooldownMs) return;
      this.lastCriticalWarningTime = now;
      log.debug("Critical buffer level detected");
      // Don't auto-pause, just log - browser handles this natively
    }
  }

  _isInStartupGrace(now = Date.now()) {
    if (!this.playbackStartTime) return false;
    return now - this.playbackStartTime < this.config.startupGraceMs;
  }

  _isInSeekGrace(now = Date.now()) {
    if (!this.lastSeekTime) return false;
    return now - this.lastSeekTime < this.config.seekGraceMs;
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
    if (!this.video) return 0;

    const buffered = this.video.buffered;
    if (!buffered || buffered.length === 0) return 0;

    const currentTime = this.video.currentTime;
    let bufferedAhead = 0;

    // Find the buffer range that contains current time
    for (let i = 0; i < buffered.length; i++) {
      const start = buffered.start(i);
      const end = buffered.end(i);

      // If current time is within this range
      if (currentTime >= start - 0.5 && currentTime <= end) {
        bufferedAhead = end - currentTime;
        break;
      }
      // If current time is before this range (buffered ahead)
      if (currentTime < start && i === 0) {
        bufferedAhead = 0;
        break;
      }
    }

    // Also check the last buffer range (common for progressive MP4)
    if (bufferedAhead === 0 && buffered.length > 0) {
      const lastEnd = buffered.end(buffered.length - 1);
      const lastStart = buffered.start(buffered.length - 1);
      if (currentTime >= lastStart && currentTime <= lastEnd) {
        bufferedAhead = lastEnd - currentTime;
      }
    }

    return Math.max(0, bufferedAhead);
  }

  /**
   * Get current buffer health state
   * Takes into account video readyState to avoid false alarms
   */
  getBufferHealth() {
    const buffered = this.getBufferedAhead();

    // If video reports HAVE_ENOUGH_DATA, trust it even if buffer calc shows 0
    // This handles resume scenarios where playback is from cache, not buffer
    if (this.video && this.video.readyState >= 3 && buffered === 0) {
      // Check if video is actually playing smoothly
      if (!this.video.paused && !this.video.seeking) {
        return BufferHealth.GOOD; // Trust browser's readyState
      }
    }

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
