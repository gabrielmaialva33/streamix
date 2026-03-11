/**
 * WatchPartySync — Companion hook for synchronized group viewing.
 *
 * Protocol: Leader-Follower
 * - Host controls playback, followers adjust via sync commands
 * - Drift <40ms → ignore
 * - Drift <2s → adjust playbackRate (sqrt curve)
 * - Drift >2s → force seek
 * - Sync beacon every 5s from all clients
 * - Actions scheduled with target_time (server wall + 300ms delay)
 */
const WatchPartySync = {
  mounted() {
    this.isHost = this.el.dataset.isHost === "true";
    this.roomId = this.el.dataset.roomId;
    this.syncLock = false;
    this.syncLockTimeout = null;
    this.beaconInterval = null;
    this.videoEl = null;
    this.playerHook = null;

    // Wait for VideoPlayer hook to be ready
    this._waitForPlayer();

    // Handle sync commands from server
    this.handleEvent("wp_sync_command", (cmd) => this._handleSyncCommand(cmd));

    // Handle floating reactions
    this.handleEvent("wp_floating_reaction", (data) =>
      this._showFloatingReaction(data)
    );

    // Copy invite link handler
    window.addEventListener("phx:copy", (e) => {
      if (e.detail?.text) {
        navigator.clipboard.writeText(e.detail.text).catch(() => {});
      }
    });
  },

  destroyed() {
    if (this.beaconInterval) clearInterval(this.beaconInterval);
    this._unwrapPlayerEvents();
  },

  _waitForPlayer(attempts = 0) {
    // Find the video element managed by VideoPlayer hook
    const videoEl = document.querySelector("video");
    if (videoEl) {
      this.videoEl = videoEl;
      this._wrapPlayerEvents();
      this._startBeacon();
      return;
    }

    if (attempts < 50) {
      setTimeout(() => this._waitForPlayer(attempts + 1), 200);
    }
  },

  _wrapPlayerEvents() {
    if (!this.videoEl) return;

    if (this.isHost) {
      // Host: intercept play/pause/seek and notify server
      this._onPlay = () => {
        if (this.syncLock) return;
        this.pushEvent("wp_play", { position: this.videoEl.currentTime });
      };
      this._onPause = () => {
        if (this.syncLock) return;
        this.pushEvent("wp_pause", { position: this.videoEl.currentTime });
      };
      this._onSeeked = () => {
        if (this.syncLock) return;
        this.pushEvent("wp_seek", { position: this.videoEl.currentTime });
      };

      this.videoEl.addEventListener("play", this._onPlay);
      this.videoEl.addEventListener("pause", this._onPause);
      this.videoEl.addEventListener("seeked", this._onSeeked);
    }
    // Followers don't block controls — drift correction handles sync
  },

  _unwrapPlayerEvents() {
    if (!this.videoEl) return;

    if (this._onPlay)
      this.videoEl.removeEventListener("play", this._onPlay);
    if (this._onPause)
      this.videoEl.removeEventListener("pause", this._onPause);
    if (this._onSeeked)
      this.videoEl.removeEventListener("seeked", this._onSeeked);
  },

  _handleSyncCommand(cmd) {
    if (!this.videoEl || this.isHost) return;

    const now = Date.now();
    const delay = cmd.target_time ? Math.max(0, cmd.target_time - now) : 0;

    setTimeout(() => {
      this._setSyncLock();

      switch (cmd.type) {
        case "play":
          this.videoEl.currentTime = cmd.position;
          this.videoEl.play().catch(() => {});
          break;

        case "pause":
          this.videoEl.currentTime = cmd.position;
          this.videoEl.pause();
          break;

        case "seek":
          this.videoEl.currentTime = cmd.position;
          break;

        case "sync":
          this._correctDrift(cmd.position, cmd.state);
          break;
      }
    }, delay);
  },

  _correctDrift(serverPosition, serverState) {
    if (!this.videoEl) return;

    const currentPos = this.videoEl.currentTime;
    const drift = Math.abs(currentPos - serverPosition);

    // Handle play/pause state mismatch
    if (serverState === "playing" && this.videoEl.paused) {
      this.videoEl.currentTime = serverPosition;
      this.videoEl.play().catch(() => {});
      return;
    }
    if (serverState === "paused" && !this.videoEl.paused) {
      this.videoEl.currentTime = serverPosition;
      this.videoEl.pause();
      return;
    }

    if (drift < 0.04) {
      // <40ms drift — ignore, reset playback rate
      this.videoEl.playbackRate = 1.0;
      return;
    }

    if (drift > 2.0) {
      // >2s drift — force seek
      this.videoEl.currentTime = serverPosition;
      this.videoEl.playbackRate = 1.0;
      return;
    }

    // <2s drift — adjust playbackRate using sqrt curve
    const direction = currentPos < serverPosition ? 1 : -1;
    const adjustment = Math.sqrt(drift) * 0.1;
    this.videoEl.playbackRate = 1.0 + direction * adjustment;

    // Reset playback rate after correction window
    setTimeout(() => {
      if (this.videoEl) this.videoEl.playbackRate = 1.0;
    }, 2000);
  },

  _startBeacon() {
    this.beaconInterval = setInterval(() => {
      if (!this.videoEl) return;
      this.pushEvent("wp_sync_beacon", {
        position: this.videoEl.currentTime,
        client_time: Date.now(),
      });
    }, 5000);
  },

  _setSyncLock() {
    this.syncLock = true;
    if (this.syncLockTimeout) clearTimeout(this.syncLockTimeout);
    this.syncLockTimeout = setTimeout(() => {
      this.syncLock = false;
    }, 2000);
  },

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
