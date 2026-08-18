import { PLAYBACK_BRIDGE_EVENT } from "../player/playback_bridge";

/**
 * WatchPartySync v2 — Enhanced synchronized group viewing.
 *
 * Improvements over v1:
 * - Server clock offset estimation via RTT ping/pong
 * - Lower drift thresholds (0.5s force seek vs 2s)
 * - Buffering awareness (no corrections while buffering)
 * - Smoother playbackRate correction with exponential decay
 * - Adaptive sync beacon interval (1s catchup, 5s normal, 10s synced)
 * - Immediate sync on join (no waiting for first beacon)
 * - Per-participant drift tracking on server
 */
const WatchPartySync = {
  mounted() {
    this.isHost = this.el.dataset.isHost === "true";
    this.roomId = this.el.dataset.roomId;
    this.syncLock = false;
    this.syncLockTimeout = null;
    this.beaconInterval = null;
    this.videoEl = null;
    this.playerEl = null;
    this.playback = null;
    this.isBuffering = false;
    this.lastCorrectionTime = 0;
    this.currentBeaconMs = 5000;
    this.rateResetTimer = null;
    this.clockOffset = 0; // local - server (ms)
    this.clockOffsetSamples = [];
    this.clockPingId = 0;
    this.clockPingAttempts = 0;
    this.clockPings = new Map();
    this.clockPingTimer = null;
    this.lastServerCommandTime = 0;

    this._waitForPlayer();

    // Handle sync commands from server
    this.handleEvent("wp_sync_command", (cmd) => this._handleSyncCommand(cmd));

    // Handle floating reactions
    this.handleEvent("wp_floating_reaction", (data) => this._showFloatingReaction(data));

    // Handle clock pong (server responding to our ping)
    this.handleEvent("wp_clock_pong", (data) => this._handleClockPong(data));

    // Copy invite link handler
    this._copyHandler = (e) => {
      if (e.detail?.text) {
        navigator.clipboard.writeText(e.detail.text).catch(() => {});
      }
    };
    window.addEventListener("phx:copy", this._copyHandler);

    this._visibilityHandler = () => {
      if (document.visibilityState === "visible") {
        this._estimateClockOffset();
        this.pushEvent("wp_request_sync", {});
      }
    };
    document.addEventListener("visibilitychange", this._visibilityHandler);
  },

  destroyed() {
    if (this.beaconInterval) clearInterval(this.beaconInterval);
    if (this.rateResetTimer) clearTimeout(this.rateResetTimer);
    if (this.syncLockTimeout) clearTimeout(this.syncLockTimeout);
    if (this.clockPingTimer) clearTimeout(this.clockPingTimer);
    for (const ping of this.clockPings.values()) clearTimeout(ping.timeout);
    this.clockPings.clear();
    this._unwrapPlayerEvents();
    window.removeEventListener("phx:copy", this._copyHandler);
    document.removeEventListener("visibilitychange", this._visibilityHandler);
  },

  _waitForPlayer(attempts = 0) {
    // The bridge is the source of truth for playback: it follows whichever
    // engine the VideoPlayer hook picked. `videoEl` is still tracked for
    // buffering events and native-HLS detection, but reads and writes go
    // through the bridge — poking `<video>` directly is a no-op while
    // AVPlayer (canvas) is driving.
    const playerEl = document.getElementById("video-player-container");
    const videoEl = document.querySelector("video");

    if (playerEl?.streamixPlayback && videoEl) {
      this.playerEl = playerEl;
      this.playback = playerEl.streamixPlayback;
      this.videoEl = videoEl;
      // Detect native HLS playback (iOS Safari + macOS Safari).
      // When the platform decodes the stream natively, every
      // `currentTime = X` causes a hardware-decoder flush + buffer
      // refill, and every `playbackRate` change produces a 50-100ms
      // visual stutter (Shaka Player issue #2823, marked infeasible
      // upstream). Apply a much more conservative drift profile
      // so we don't seasick the user. hls.js / mpegts paths
      // (Android, Chrome, Firefox, Edge) keep the aggressive 100ms
      // / 500ms thresholds because their decoders handle small
      // adjustments without observable hitches.
      const nativeHls =
        videoEl.canPlayType("application/vnd.apple.mpegurl") ||
        videoEl.canPlayType("application/x-mpegURL");
      this.nativeHlsPlayback = !!nativeHls;
      this._setupBufferingDetection();
      this._wrapPlayerEvents();
      this._estimateClockOffset();
      this._startBeacon();
      // Request immediate sync state
      this.pushEvent("wp_request_sync", {});
      return;
    }

    if (attempts < 50) {
      setTimeout(() => this._waitForPlayer(attempts + 1), 200);
    }
  },

  // AVPlayer seeks re-open the demuxer, so they are as disruptive as a
  // native-HLS decoder flush. Both engines get the relaxed drift profile;
  // hls.js / mpegts keep the aggressive one.
  get useConservativeSync() {
    return this.nativeHlsPlayback || this.playback?.engine === "avplayer";
  },

  // ==========================================
  // Clock offset estimation (NTP-like)
  // ==========================================

  _estimateClockOffset() {
    // Send 5 pings, take median RTT for offset
    this.clockOffsetSamples = [];
    this.clockPingAttempts = 0;
    for (const ping of this.clockPings.values()) clearTimeout(ping.timeout);
    this.clockPings.clear();
    if (this.clockPingTimer) clearTimeout(this.clockPingTimer);
    this._sendClockPing();
  },

  _sendClockPing() {
    if (this.clockPingAttempts >= 5) {
      this._computeClockOffset();
      return;
    }
    this.clockPingAttempts++;
    this.clockPingId++;
    const id = this.clockPingId;
    const startedAt = Date.now();
    const timeout = setTimeout(() => {
      this.clockPings.delete(id);
      this._scheduleClockPing();
    }, 2000);
    this.clockPings.set(id, { startedAt, timeout });

    this.pushEvent("wp_clock_ping", {
      id,
      client_time: startedAt,
    });
  },

  _handleClockPong(data) {
    const ping = this.clockPings.get(data.id);
    if (!ping) return;

    clearTimeout(ping.timeout);
    this.clockPings.delete(data.id);

    const now = Date.now();
    const rtt = now - ping.startedAt;
    const serverTime = data.server_time;
    // Offset = (client_send + client_receive) / 2 - server_time
    const offset = (ping.startedAt + now) / 2 - serverTime;

    if (rtt < 1000) {
      // Only use samples with reasonable RTT
      this.clockOffsetSamples.push({ offset, rtt });
    }

    this._scheduleClockPing();
  },

  _scheduleClockPing() {
    if (this.clockPingTimer) clearTimeout(this.clockPingTimer);
    this.clockPingTimer = setTimeout(() => this._sendClockPing(), 200);
  },

  _computeClockOffset() {
    if (this.clockOffsetSamples.length === 0) return;

    // Discard slow samples, then use the median offset so one lucky but
    // asymmetric request cannot pull every viewer out of sync.
    const offsets = [...this.clockOffsetSamples]
      .sort((a, b) => a.rtt - b.rtt)
      .slice(0, 3)
      .map((sample) => sample.offset)
      .sort((a, b) => a - b);
    this.clockOffset = offsets[Math.floor(offsets.length / 2)];

    // clock synced
  },

  _serverNow() {
    return Date.now() - this.clockOffset;
  },

  // ==========================================
  // Buffering detection
  // ==========================================

  // Buffering suppression is native-element only: AVPlayer exposes no
  // equivalent event, so `isBuffering` stays false there and corrections
  // are applied unconditionally — safe, just slightly less polite.
  _setupBufferingDetection() {
    if (!this.videoEl) return;

    this._onWaiting = () => {
      this.isBuffering = true;
    };
    this._onCanPlay = () => {
      this.isBuffering = false;
    };
    this._onPlaying = () => {
      this.isBuffering = false;
    };

    this.videoEl.addEventListener("waiting", this._onWaiting);
    this.videoEl.addEventListener("canplay", this._onCanPlay);
    this.videoEl.addEventListener("playing", this._onPlaying);
  },

  // ==========================================
  // Player event wrapping (host only)
  // ==========================================

  _wrapPlayerEvents() {
    if (!this.playerEl || !this.isHost) return;

    // Host: the bridge reports play/pause/seek for whichever engine is
    // running, so a host on AVPlayer broadcasts commands just like a host
    // on the native element.
    const EVENT_TO_PUSH = { play: "wp_play", pause: "wp_pause", seeked: "wp_seek" };

    this._onPlaybackEvent = (event) => {
      if (this.syncLock) return;

      const push = EVENT_TO_PUSH[event.detail?.type];
      if (!push) return;

      this.pushEvent(push, { position: this._position() });
    };

    this.playerEl.addEventListener(PLAYBACK_BRIDGE_EVENT, this._onPlaybackEvent);
  },

  _unwrapPlayerEvents() {
    if (this.playerEl && this._onPlaybackEvent) {
      this.playerEl.removeEventListener(PLAYBACK_BRIDGE_EVENT, this._onPlaybackEvent);
    }

    if (!this.videoEl) return;

    if (this._onWaiting) this.videoEl.removeEventListener("waiting", this._onWaiting);
    if (this._onCanPlay) this.videoEl.removeEventListener("canplay", this._onCanPlay);
    if (this._onPlaying) this.videoEl.removeEventListener("playing", this._onPlaying);
  },

  _position() {
    return this.playback ? this.playback.getCurrentTime() : 0;
  },

  _isPaused() {
    return this.playback ? this.playback.isPaused() : true;
  },

  // ==========================================
  // Sync command handling (follower)
  // ==========================================

  _handleSyncCommand(cmd) {
    if (!this.playback) return;

    // Host ignores sync commands (they are the source of truth)
    if (this.isHost) return;

    if (cmd.server_time && cmd.server_time <= this.lastServerCommandTime) return;
    if (cmd.server_time) this.lastServerCommandTime = cmd.server_time;

    // Don't apply corrections while buffering
    if (this.isBuffering && cmd.type === "sync") return;

    if (cmd.type === "sync") {
      // Periodic sync — correct drift
      this._correctDrift(cmd.position, cmd.state, cmd.server_time);
    } else {
      // Action commands (play/pause/seek) — apply with delay
      const delay = cmd.target_time ? Math.max(0, cmd.target_time - this._serverNow()) : 0;

      setTimeout(() => {
        this._setSyncLock();

        switch (cmd.type) {
          case "play": {
            // iOS Safari with native HLS: writing `currentTime`
            // immediately before `.play()` aborts the play
            // promise (`AbortError: interrupted by new load`),
            // and the guest stays stuck paused. Start playback
            // first so the user-gesture chain stays intact, then
            // nudge the position once it is actually running.
            const targetPosition = cmd.position;
            const driftThreshold = this.useConservativeSync ? 1.0 : 0.3;

            this.playback.play();

            setTimeout(() => {
              if (!this.playback) return;
              if (Math.abs(this._position() - targetPosition) > driftThreshold) {
                this.playback.seekTo(targetPosition);
              }
            }, 150);
            break;
          }

          case "pause":
            this.playback.pause();
            this.playback.seekTo(cmd.position);
            break;

          case "seek":
            this.playback.seekTo(cmd.position);
            break;
        }
      }, delay);
    }
  },

  _correctDrift(serverPosition, serverState, serverTime) {
    if (!this.playback) return;

    // Compensate for time elapsed since server sent the sync
    const timeSinceSync = (this._serverNow() - serverTime) / 1000;
    let targetPosition = serverPosition;
    if (serverState === "playing") {
      targetPosition += Math.max(0, timeSinceSync);
    }

    const currentPos = this._position();
    const drift = currentPos - targetPosition; // positive = ahead, negative = behind
    const absDrift = Math.abs(drift);

    // Handle play/pause state mismatch first
    if (serverState === "playing" && this._isPaused()) {
      this._setSyncLock();
      // Play first, seek after (iOS native-HLS aborts the play
      // promise if currentTime is written immediately before).
      this.playback.play();
      if (absDrift > (this.useConservativeSync ? 1.0 : 0.3)) {
        this.playback.seekTo(targetPosition);
      }
      this._setAdaptiveBeacon("catchup");
      return;
    }
    if (serverState === "paused" && !this._isPaused()) {
      this._setSyncLock();
      this.playback.pause();
      this.playback.seekTo(targetPosition);
      this._setAdaptiveBeacon("synced");
      return;
    }

    // Two profiles. Conservative is for native HLS clients (iOS / macOS
    // Safari) that visibly stutter on `playbackRate` changes and on any
    // `currentTime` write. User direction: "no problem if iOS isn't
    // perfectly in sync, the important thing is that it stays smooth"
    // — so we accept up to 1s of drift silently and only catch up
    // beyond 3s. Aggressive matches the PubNub-tuned defaults the rest
    // of the web tolerates fine.
    const syncedThreshold = this.useConservativeSync ? 1.0 : 0.1;
    const seekThreshold = this.useConservativeSync ? 3.0 : 0.5;

    if (absDrift < syncedThreshold) {
      // Below "synced" threshold — accept the drift, reset rate, relax beacon
      this._resetPlaybackRate();
      this._setAdaptiveBeacon("synced");
      return;
    }

    if (absDrift > seekThreshold) {
      // Hard catchup — single seek + sync lock so the seeked event
      // doesn't bounce back as a wp_seek to the server.
      this._setSyncLock();
      this.playback.seekTo(targetPosition);
      this._resetPlaybackRate();
      this._setAdaptiveBeacon("catchup");
      return;
    }

    if (this.useConservativeSync) {
      // Mid-band drift on native HLS: do nothing. Either the drift
      // collapses naturally over the next beacon cycles or it grows
      // past the seek threshold and we catch up in one shot. Tweaking
      // `playbackRate` here is what causes the iPhone microstutters
      // the user reported. Stay on the relaxed beacon — there's no
      // urgency, the host's explicit play/pause/seek commands
      // already flow through `wp_sync_command` immediately.
      this._setAdaptiveBeacon("synced");
      return;
    }

    // Aggressive (hls.js / mpegts): smooth playbackRate adjustment with
    // an exponential curve, more aggressive as drift increases.
    const direction = drift < 0 ? 1 : -1; // behind = speed up, ahead = slow down
    const normalized = absDrift / 0.5; // 0..1 range
    const adjustment = normalized * normalized * 0.15; // quadratic, max ±15%
    const newRate = 1.0 + direction * adjustment;

    this.playback.setPlaybackRate(Math.max(0.8, Math.min(1.2, newRate)));
    this._setAdaptiveBeacon("correcting");

    // Gradual reset: check again in 1s
    if (this.rateResetTimer) clearTimeout(this.rateResetTimer);
    this.rateResetTimer = setTimeout(() => {
      // Don't reset if still correcting
      if (this.videoEl && Math.abs(this.videoEl.playbackRate - 1.0) > 0.01) {
        this.playback?.setPlaybackRate(1.0);
      }
    }, 3000);
  },

  _resetPlaybackRate() {
    if (this.videoEl && this.videoEl.playbackRate !== 1.0) {
      this.playback?.setPlaybackRate(1.0);
    }
    if (this.rateResetTimer) {
      clearTimeout(this.rateResetTimer);
      this.rateResetTimer = null;
    }
  },

  // ==========================================
  // Adaptive sync beacon
  // ==========================================

  _startBeacon() {
    this._setAdaptiveBeacon("normal");
  },

  _setAdaptiveBeacon(mode) {
    const intervals = {
      catchup: 1000, // Fast sync during catch-up
      correcting: 2000, // Medium during rate correction
      normal: 5000, // Default
      synced: 8000, // Relaxed when synced
    };

    const newInterval = intervals[mode] || 5000;
    if (newInterval === this.currentBeaconMs) return;

    this.currentBeaconMs = newInterval;

    if (this.beaconInterval) clearInterval(this.beaconInterval);
    this.beaconInterval = setInterval(() => {
      if (!this.playback) return;
      this.pushEvent("wp_sync_beacon", {
        position: this._position(),
        state: this._isPaused() ? "paused" : "playing",
        buffering: this.isBuffering,
        client_time: Date.now(),
      });
    }, this.currentBeaconMs);
  },

  // ==========================================
  // Sync lock (prevents echo loops)
  // ==========================================

  _setSyncLock() {
    this.syncLock = true;
    if (this.syncLockTimeout) clearTimeout(this.syncLockTimeout);
    this.syncLockTimeout = setTimeout(() => {
      this.syncLock = false;
    }, 1500);
  },

  // ==========================================
  // Floating reactions
  // ==========================================

  _showFloatingReaction(data) {
    const container = document.getElementById("wp-reactions-container");
    if (!container) return;

    const el = document.createElement("div");
    el.className = "floating-reaction";
    el.textContent = data.emoji;
    el.style.left = `${Math.random() * 80}px`;
    container.appendChild(el);

    setTimeout(() => el.remove(), 2000);
  },
};

export default WatchPartySync;
