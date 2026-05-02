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
        this.isBuffering = false;
        this.lastCorrectionTime = 0;
        this.currentBeaconMs = 5000;
        this.rateResetTimer = null;
        this.clockOffset = 0; // local - server (ms)
        this.clockOffsetSamples = [];
        this.clockPingId = 0;
        this.clockPingStart = 0;

        this._waitForPlayer();

        // Handle sync commands from server
        this.handleEvent("wp_sync_command", (cmd) => this._handleSyncCommand(cmd));

        // Handle floating reactions
        this.handleEvent("wp_floating_reaction", (data) =>
            this._showFloatingReaction(data),
        );

        // Handle clock pong (server responding to our ping)
        this.handleEvent("wp_clock_pong", (data) => this._handleClockPong(data));

        // Copy invite link handler
        this._copyHandler = (e) => {
            if (e.detail?.text) {
                navigator.clipboard.writeText(e.detail.text).catch(() => {
                });
            }
        };
        window.addEventListener("phx:copy", this._copyHandler);
    },

    destroyed() {
        if (this.beaconInterval) clearInterval(this.beaconInterval);
        if (this.rateResetTimer) clearTimeout(this.rateResetTimer);
        if (this.syncLockTimeout) clearTimeout(this.syncLockTimeout);
        this._unwrapPlayerEvents();
        window.removeEventListener("phx:copy", this._copyHandler);
    },

    _waitForPlayer(attempts = 0) {
        const videoEl = document.querySelector("video");
        if (videoEl) {
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
            this.useConservativeSync = !!nativeHls;
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

    // ==========================================
    // Clock offset estimation (NTP-like)
    // ==========================================

    _estimateClockOffset() {
        // Send 5 pings, take median RTT for offset
        this.clockOffsetSamples = [];
        this._sendClockPing();
    },

    _sendClockPing() {
        if (this.clockOffsetSamples.length >= 5) {
            this._computeClockOffset();
            return;
        }
        this.clockPingId++;
        this.clockPingStart = Date.now();
        this.pushEvent("wp_clock_ping", {
            id: this.clockPingId,
            client_time: this.clockPingStart,
        });
        // If no pong in 2s, skip this sample
        setTimeout(() => {
            if (this.clockOffsetSamples.length < this.clockPingId) {
                this._sendClockPing();
            }
        }, 2000);
    },

    _handleClockPong(data) {
        const now = Date.now();
        const rtt = now - this.clockPingStart;
        const serverTime = data.server_time;
        // Offset = (client_send + client_receive) / 2 - server_time
        const offset = (this.clockPingStart + now) / 2 - serverTime;

        if (rtt < 1000) {
            // Only use samples with reasonable RTT
            this.clockOffsetSamples.push({offset, rtt});
        }

        // Send next ping after short delay
        setTimeout(() => this._sendClockPing(), 200);
    },

    _computeClockOffset() {
        if (this.clockOffsetSamples.length === 0) return;

        // Sort by RTT, take median offset (lowest RTT = most accurate)
        const sorted = [...this.clockOffsetSamples].sort(
            (a, b) => a.rtt - b.rtt,
        );
        // Use the sample with lowest RTT (most accurate)
        this.clockOffset = sorted[0].offset;

        // clock synced
    },

    _serverNow() {
        return Date.now() - this.clockOffset;
    },

    // ==========================================
    // Buffering detection
    // ==========================================

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
        if (!this.videoEl || !this.isHost) return;

        // Host: intercept play/pause/seek and notify server
        this._onPlay = () => {
            if (this.syncLock) return;
            this.pushEvent("wp_play", {position: this.videoEl.currentTime});
        };
        this._onPause = () => {
            if (this.syncLock) return;
            this.pushEvent("wp_pause", {position: this.videoEl.currentTime});
        };
        this._onSeeked = () => {
            if (this.syncLock) return;
            this.pushEvent("wp_seek", {position: this.videoEl.currentTime});
        };

        this.videoEl.addEventListener("play", this._onPlay);
        this.videoEl.addEventListener("pause", this._onPause);
        this.videoEl.addEventListener("seeked", this._onSeeked);
    },

    _unwrapPlayerEvents() {
        if (!this.videoEl) return;

        if (this._onPlay)
            this.videoEl.removeEventListener("play", this._onPlay);
        if (this._onPause)
            this.videoEl.removeEventListener("pause", this._onPause);
        if (this._onSeeked)
            this.videoEl.removeEventListener("seeked", this._onSeeked);
        if (this._onWaiting)
            this.videoEl.removeEventListener("waiting", this._onWaiting);
        if (this._onCanPlay)
            this.videoEl.removeEventListener("canplay", this._onCanPlay);
        if (this._onPlaying)
            this.videoEl.removeEventListener("playing", this._onPlaying);
    },

    // ==========================================
    // Sync command handling (follower)
    // ==========================================

    _handleSyncCommand(cmd) {
        if (!this.videoEl) return;

        // Host ignores sync commands (they are the source of truth)
        if (this.isHost) return;

        // Don't apply corrections while buffering
        if (this.isBuffering && cmd.type === "sync") return;

        const now = Date.now();

        if (cmd.type === "sync") {
            // Periodic sync — correct drift
            this._correctDrift(cmd.position, cmd.state, cmd.server_time);
        } else {
            // Action commands (play/pause/seek) — apply with delay
            const delay = cmd.target_time
                ? Math.max(0, cmd.target_time - this._serverNow())
                : 0;

            setTimeout(() => {
                this._setSyncLock();

                switch (cmd.type) {
                    case "play":
                        this.videoEl.currentTime = cmd.position;
                        this.videoEl.play().catch(() => {
                        });
                        break;

                    case "pause":
                        this.videoEl.pause();
                        this.videoEl.currentTime = cmd.position;
                        break;

                    case "seek":
                        this.videoEl.currentTime = cmd.position;
                        break;
                }
            }, delay);
        }
    },

    _correctDrift(serverPosition, serverState, serverTime) {
        if (!this.videoEl) return;

        // Compensate for time elapsed since server sent the sync
        const timeSinceSync = (this._serverNow() - serverTime) / 1000;
        let targetPosition = serverPosition;
        if (serverState === "playing") {
            targetPosition += Math.max(0, timeSinceSync);
        }

        const currentPos = this.videoEl.currentTime;
        const drift = currentPos - targetPosition; // positive = ahead, negative = behind
        const absDrift = Math.abs(drift);

        // Handle play/pause state mismatch first
        if (serverState === "playing" && this.videoEl.paused) {
            this._setSyncLock();
            this.videoEl.currentTime = targetPosition;
            this.videoEl.play().catch(() => {
            });
            this._setAdaptiveBeacon("catchup");
            return;
        }
        if (serverState === "paused" && !this.videoEl.paused) {
            this._setSyncLock();
            this.videoEl.pause();
            this.videoEl.currentTime = targetPosition;
            this._setAdaptiveBeacon("synced");
            return;
        }

        // Two profiles. Conservative is for native HLS clients (iOS / macOS
        // Safari) that visibly stutter on `playbackRate` changes and on any
        // `currentTime` write — the threshold gap goes from 0.1s/0.5s to
        // 0.3s/1.5s, and the smooth playbackRate band is removed entirely.
        // Aggressive matches the PubNub-tuned defaults the rest of the web
        // tolerates fine.
        const syncedThreshold = this.useConservativeSync ? 0.3 : 0.1;
        const seekThreshold = this.useConservativeSync ? 1.5 : 0.5;

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
            this.videoEl.currentTime = targetPosition;
            this._resetPlaybackRate();
            this._setAdaptiveBeacon("catchup");
            return;
        }

        if (this.useConservativeSync) {
            // Mid-band drift on native HLS: do nothing. Either the drift
            // collapses naturally over the next beacon cycles or it grows
            // past the seek threshold and we catch up in one shot. Tweaking
            // playbackRate here is what causes the iPhone microstutters
            // the user reported.
            this._setAdaptiveBeacon("normal");
            return;
        }

        // Aggressive (hls.js / mpegts): smooth playbackRate adjustment with
        // an exponential curve, more aggressive as drift increases.
        const direction = drift < 0 ? 1 : -1; // behind = speed up, ahead = slow down
        const normalized = absDrift / 0.5; // 0..1 range
        const adjustment = normalized * normalized * 0.15; // quadratic, max ±15%
        const newRate = 1.0 + direction * adjustment;

        this.videoEl.playbackRate = Math.max(0.8, Math.min(1.2, newRate));
        this._setAdaptiveBeacon("correcting");

        // Gradual reset: check again in 1s
        if (this.rateResetTimer) clearTimeout(this.rateResetTimer);
        this.rateResetTimer = setTimeout(() => {
            // Don't reset if still correcting
            if (this.videoEl && Math.abs(this.videoEl.playbackRate - 1.0) > 0.01) {
                this.videoEl.playbackRate = 1.0;
            }
        }, 3000);
    },

    _resetPlaybackRate() {
        if (this.videoEl && this.videoEl.playbackRate !== 1.0) {
            this.videoEl.playbackRate = 1.0;
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
            if (!this.videoEl) return;
            this.pushEvent("wp_sync_beacon", {
                position: this.videoEl.currentTime,
                state: this.videoEl.paused ? "paused" : "playing",
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
