import { PLAYBACK_BRIDGE_EVENT } from "../player/playback_bridge.js";

const PLAYER_READY_EVENT = "streamix:playback-ready";
const BUFFERING_EVENT = "streamix:buffering";
const MAX_ACTION_DELAY_MS = 1500;
const PLAYER_POLL_FAST_ATTEMPTS = 50;

const WatchPartySync = {
  mounted() {
    this.isHost = this.el.dataset.isHost === "true";
    this.roomId = this.el.dataset.roomId;
    this.el.__watchPartySyncHook = this;
    this.connectedToLiveView = true;
    this.destroyedHook = false;
    this.playerEl = null;
    this.videoEl = null;
    this.playback = null;
    this.playerWaitTimer = null;
    this.beaconInterval = null;
    this.currentBeaconMs = null;
    this.rateResetTimer = null;
    this.syncLock = false;
    this.syncLockTimeout = null;
    this.syncHold = !this.isHost;
    this.syncHoldReason = this.isHost ? null : "connecting";
    this.isBuffering = false;
    this.nativeHlsPlayback = false;
    this.clockOffset = 0;
    this.clockReady = false;
    this.clockOffsetSamples = [];
    this.clockPingId = 0;
    this.clockPingAttempts = 0;
    this.clockPings = new Map();
    this.clockPingTimer = null;
    this.lastServerSequence = 0;
    this.lastServerCommandTime = 0;
    this.lastHostStatus = null;
    this.commandGeneration = 0;
    this.pendingCommandTimers = new Set();
    this.reactionTimers = new Set();
    this.lastPublishedStatus = null;
    this.lastPublishedDrift = null;

    this.handleEvent("wp_sync_command", (command) => this._handleSyncCommand(command));
    this.handleEvent("wp_floating_reaction", (data) => this._showFloatingReaction(data));
    this.handleEvent("wp_clock_pong", (data) => this._handleClockPong(data));
    this.handleEvent("wp_host_status", (data) => this._handleHostStatus(data));

    this._onPlaybackReady = () => {
      if (this._ensurePlayerBinding()) {
        this._applyHostSnapshot();
        this._applyServerSnapshot();
      } else {
        this._waitForPlayer(0);
      }
    };
    document.addEventListener(PLAYER_READY_EVENT, this._onPlaybackReady);

    this._copyHandler = (event) => this._copyInvite(event);
    window.addEventListener("phx:copy", this._copyHandler);

    this._visibilityHandler = () => {
      if (document.visibilityState !== "visible" || this.destroyedHook) return;
      this._estimateClockOffset();
      this._safePush("wp_request_sync", {});
      this._sendBeacon();
    };
    document.addEventListener("visibilitychange", this._visibilityHandler);

    this._waitForPlayer(0);
  },

  disconnected() {
    this.connectedToLiveView = false;
    this._stopBeacon();
    this._cancelPendingCommands();
    this._clearClockTimers();
    this._resetPlaybackRate();
    this._setSyncHold(true, "disconnected");
    this._publishStatus("disconnected");
  },

  reconnected() {
    this.connectedToLiveView = true;
    if (!this.isHost) this._setSyncHold(true, "connecting");
    this._applyHostSnapshot();
    this._estimateClockOffset();
    this._startBeacon();
    this._safePush("wp_request_sync", {});
    this._sendBeacon();
    this._publishStatus(this.isHost ? "synced" : "connecting");
  },

  updated() {
    if (this.el) this.el.__watchPartySyncHook = this;
    this._ensurePlayerBinding();
    this._applyHostSnapshot();
    this._applyServerSnapshot();

    if (this.lastPublishedStatus) {
      this._renderStatus(this.lastPublishedStatus, this.lastPublishedDrift);
    }
  },

  destroyed() {
    this.destroyedHook = true;
    this.connectedToLiveView = false;
    this._stopBeacon();
    this._cancelPendingCommands();
    this._clearClockTimers();
    this._clearTimer("playerWaitTimer");
    this._clearTimer("rateResetTimer");
    this._clearTimer("syncLockTimeout");
    this._setSyncHold(false);
    this._unbindPlayer();

    for (const timer of this.reactionTimers) clearTimeout(timer);
    this.reactionTimers.clear();

    document.removeEventListener(PLAYER_READY_EVENT, this._onPlaybackReady);
    document.removeEventListener("visibilitychange", this._visibilityHandler);
    window.removeEventListener("phx:copy", this._copyHandler);
    if (this.el?.__watchPartySyncHook === this) delete this.el.__watchPartySyncHook;
  },

  get useConservativeSync() {
    return this.nativeHlsPlayback || this.playback?.supportsPlaybackRate?.() === false;
  },

  _waitForPlayer(attempts = 0) {
    if (this.destroyedHook) return;
    if (this._ensurePlayerBinding()) return;

    const delay = attempts < PLAYER_POLL_FAST_ATTEMPTS ? 200 : 2000;
    this._clearTimer("playerWaitTimer");
    this.playerWaitTimer = setTimeout(() => this._waitForPlayer(attempts + 1), delay);
  },

  _ensurePlayerBinding() {
    if (this.destroyedHook) return false;

    const playerEl = document.getElementById("video-player-container");
    const videoEl = playerEl?.querySelector("video") || null;
    if (!playerEl?.streamixPlayback || !videoEl) return false;

    if (
      this.playerEl !== playerEl ||
      this.playback !== playerEl.streamixPlayback ||
      playerEl.__watchPartySyncHook !== this
    ) {
      this._bindPlayer(playerEl, videoEl);
    }

    return true;
  },

  _bindPlayer(playerEl, videoEl) {
    if (
      this.playerEl === playerEl &&
      this.playback === playerEl.streamixPlayback &&
      playerEl.__watchPartySyncHook === this
    ) {
      return;
    }

    this._unbindPlayer();
    this._clearTimer("playerWaitTimer");
    this.playerEl = playerEl;
    this.videoEl = videoEl;
    this.playback = playerEl.streamixPlayback;
    this.playback.setSyncHold?.(this.syncHold);
    playerEl.__watchPartySyncHook = this;
    this.nativeHlsPlayback = Boolean(
      videoEl.canPlayType("application/vnd.apple.mpegurl") ||
        videoEl.canPlayType("application/x-mpegURL"),
    );

    this._onBufferingEvent = (event) => {
      if (typeof event.detail?.buffering === "boolean") {
        this._setBuffering(event.detail.buffering);
      }
    };
    playerEl.addEventListener(BUFFERING_EVENT, this._onBufferingEvent);

    this._onWaiting = () => this._setBuffering(true);
    this._onCanPlay = () => this._setBuffering(false);
    this._onPlaying = () => this._setBuffering(false);
    videoEl.addEventListener("waiting", this._onWaiting);
    videoEl.addEventListener("canplay", this._onCanPlay);
    videoEl.addEventListener("playing", this._onPlaying);

    if (this.isHost) {
      const eventToPush = { play: "wp_play", pause: "wp_pause", seeked: "wp_seek" };
      this._onPlaybackEvent = (event) => {
        if (this.syncLock || this.destroyedHook) return;
        const pushEvent = eventToPush[event.detail?.type];
        if (pushEvent) this._safePush(pushEvent, { position: this._position() });
      };
      playerEl.addEventListener(PLAYBACK_BRIDGE_EVENT, this._onPlaybackEvent);
    }

    this._applyHostSnapshot();
    this._applyServerSnapshot();
    this._estimateClockOffset();
    this._startBeacon();
    this._sendBeacon();
    this._safePush("wp_request_sync", {});
    this._publishStatus(this.isHost ? "synced" : "connecting");
  },

  _unbindPlayer() {
    this.playback?.setSyncHold?.(false);

    if (this.playerEl?.__watchPartySyncHook === this) {
      delete this.playerEl.__watchPartySyncHook;
    }

    if (this.playerEl && this._onPlaybackEvent) {
      this.playerEl.removeEventListener(PLAYBACK_BRIDGE_EVENT, this._onPlaybackEvent);
    }
    if (this.playerEl && this._onBufferingEvent) {
      this.playerEl.removeEventListener(BUFFERING_EVENT, this._onBufferingEvent);
    }
    if (this.videoEl) {
      if (this._onWaiting) this.videoEl.removeEventListener("waiting", this._onWaiting);
      if (this._onCanPlay) this.videoEl.removeEventListener("canplay", this._onCanPlay);
      if (this._onPlaying) this.videoEl.removeEventListener("playing", this._onPlaying);
    }

    this._onPlaybackEvent = null;
    this._onBufferingEvent = null;
    this._onWaiting = null;
    this._onCanPlay = null;
    this._onPlaying = null;
    this.playerEl = null;
    this.videoEl = null;
    this.playback = null;
  },

  _setBuffering(buffering) {
    const changed = this.isBuffering !== buffering;
    this.isBuffering = buffering;

    if (changed) {
      this._publishStatus(buffering ? "buffering" : this.isHost ? "synced" : "correcting");
    }

    // Re-send even when the local flag already matches. The first transition
    // can happen while LiveView is still joining the room; a later identical
    // media event must be able to repair the server's view of buffering.
    this._sendBeacon({ urgent: true });

    if (changed && !buffering && !this.isHost) {
      this._safePush("wp_request_sync", {});
    }
  },

  _position() {
    const position = Number(this.playback?.getCurrentTime?.());
    return Number.isFinite(position) && position >= 0 ? position : 0;
  },

  _isPaused() {
    return this.playback?.isPaused?.() ?? true;
  },

  // Clock synchronization

  _estimateClockOffset() {
    if (!this.connectedToLiveView || this.destroyedHook) return;

    this.clockReady = false;
    this.clockOffsetSamples = [];
    this.clockPingAttempts = 0;
    this._clearClockTimers();
    this._sendClockPing();
  },

  _sendClockPing() {
    if (!this.connectedToLiveView || this.destroyedHook) return;
    if (this.clockPingAttempts >= 5) {
      this._computeClockOffset();
      return;
    }

    this.clockPingAttempts += 1;
    this.clockPingId += 1;
    const id = this.clockPingId;
    const startedAt = Date.now();
    const timeout = setTimeout(() => {
      this.clockPings.delete(id);
      this._scheduleClockPing();
    }, 2000);

    this.clockPings.set(id, { startedAt, timeout });
    this._safePush("wp_clock_ping", { id, client_time: startedAt });
  },

  _handleClockPong(data) {
    const ping = this.clockPings.get(data?.id);
    const serverTime = Number(data?.server_time);
    if (!ping || !Number.isFinite(serverTime)) return;

    clearTimeout(ping.timeout);
    this.clockPings.delete(data.id);

    const receivedAt = Date.now();
    const rtt = receivedAt - ping.startedAt;
    if (rtt >= 0 && rtt < 1000) {
      this.clockOffsetSamples.push({
        offset: (ping.startedAt + receivedAt) / 2 - serverTime,
        rtt,
      });
    }

    this._scheduleClockPing();
  },

  _scheduleClockPing() {
    this._clearTimer("clockPingTimer");
    this.clockPingTimer = setTimeout(() => this._sendClockPing(), 200);
  },

  _computeClockOffset() {
    if (this.clockOffsetSamples.length === 0) return;

    const offsets = [...this.clockOffsetSamples]
      .sort((left, right) => left.rtt - right.rtt)
      .slice(0, 3)
      .map((sample) => sample.offset)
      .sort((left, right) => left - right);

    this.clockOffset = offsets[Math.floor(offsets.length / 2)];
    this.clockReady = true;
  },

  _serverNow() {
    return Date.now() - this.clockOffset;
  },

  _clearClockTimers() {
    this._clearTimer("clockPingTimer");
    for (const ping of this.clockPings.values()) clearTimeout(ping.timeout);
    this.clockPings.clear();
  },

  // Command ordering and correction

  _applyHostSnapshot() {
    const status = this.el?.dataset?.hostStatus;
    if (!["online", "offline"].includes(status) || status === this.lastHostStatus) return;

    this._handleHostStatus({ status });
  },

  _applyServerSnapshot() {
    if (!this.playback || this.isHost || this.destroyedHook) return;

    const state = this.el.dataset.serverState;
    const position = Number(this.el.dataset.serverPosition);
    const sequence = Number(this.el.dataset.serverSequence);
    const rawServerTime = this.el.dataset.serverTime;
    const serverTime = rawServerTime ? Number(rawServerTime) : null;

    if (!["playing", "paused"].includes(state) || !Number.isFinite(position) || position < 0) {
      return;
    }

    this._handleSyncCommand({
      type: "sync",
      state,
      position,
      host_buffering: this.el.dataset.serverBuffering === "true",
      sequence: Number.isInteger(sequence) ? sequence : 0,
      server_time: Number.isFinite(serverTime) ? serverTime : null,
    });
  },

  _handleSyncCommand(command) {
    if (!this.playback || this.isHost || this.destroyedHook) return;

    if (!this._acceptCommand(command)) return;

    this._cancelPendingCommands();

    if (command.host_buffering === true) {
      this._setSyncLock();
      this._setSyncHold(true, "buffering");
      this._resetPlaybackRate();
      this._setAdaptiveBeacon("catchup");
      this._publishStatus("buffering");
      return;
    }

    if (!this.isHost && this.lastHostStatus === "offline") {
      this._setSyncHold(true, "host_offline");
    } else {
      this._setSyncHold(false);
    }

    if (this.isBuffering && command.type === "sync") {
      this._publishStatus("buffering");
      return;
    }

    if (command.type === "sync") {
      this._correctDrift(command.position, command.state, command.server_time);
      return;
    }

    if (!["play", "pause", "seek"].includes(command.type)) return;

    const delay =
      this.clockReady && Number.isFinite(Number(command.target_time))
        ? Math.min(
            MAX_ACTION_DELAY_MS,
            Math.max(0, Number(command.target_time) - this._serverNow()),
          )
        : 0;

    const generation = this.commandGeneration;
    this._scheduleCommand(() => this._applyActionCommand(command, generation), delay, generation);
  },

  _acceptCommand(command) {
    const sequence = Number(command?.sequence);
    if (Number.isInteger(sequence) && sequence > 0) {
      if (sequence < this.lastServerSequence) return false;
      if (sequence === this.lastServerSequence) {
        return this.syncHold && command?.type === "sync";
      }
      this.lastServerSequence = sequence;
      return true;
    }

    const serverTime = Number(command?.server_time);
    if (Number.isFinite(serverTime)) {
      if (serverTime <= this.lastServerCommandTime) return false;
      this.lastServerCommandTime = serverTime;
    }

    return true;
  },

  _applyActionCommand(command, generation) {
    if (!this.playback || generation !== this.commandGeneration || this.destroyedHook) return;

    const targetPosition = Number(command.position);
    if (!Number.isFinite(targetPosition) || targetPosition < 0) return;
    this._setSyncLock();

    switch (command.type) {
      case "play": {
        const driftThreshold = this.useConservativeSync ? 1.0 : 0.3;
        void Promise.resolve(this.playback.play?.()).catch(() => {});
        this._scheduleCommand(
          () => {
            if (Math.abs(this._position() - targetPosition) > driftThreshold) {
              this.playback?.seekTo?.(targetPosition);
            }
          },
          150,
          generation,
        );
        this._publishStatus("correcting");
        break;
      }
      case "pause":
        void Promise.resolve(this.playback.pause?.()).catch(() => {});
        this.playback.seekTo?.(targetPosition);
        this._publishStatus("synced");
        break;
      case "seek":
        this.playback.seekTo?.(targetPosition);
        this._publishStatus("correcting");
        break;
    }
  },

  _correctDrift(serverPosition, serverState, serverTime) {
    const position = Number(serverPosition);
    const sentAt = Number(serverTime);
    if (!Number.isFinite(position) || position < 0) return;
    if (!["playing", "paused"].includes(serverState)) return;

    const elapsed =
      serverState === "playing" && this.clockReady && Number.isFinite(sentAt)
        ? Math.max(0, Math.min(10, (this._serverNow() - sentAt) / 1000))
        : 0;
    const targetPosition = position + elapsed;
    const drift = this._position() - targetPosition;
    const absoluteDrift = Math.abs(drift);
    const driftMs = Math.round(absoluteDrift * 1000);

    if (serverState === "playing" && this._isPaused()) {
      this._setSyncLock();
      void Promise.resolve(this.playback.play?.()).catch(() => {});
      if (absoluteDrift > (this.useConservativeSync ? 1.0 : 0.3)) {
        this.playback.seekTo?.(targetPosition);
      }
      this._setAdaptiveBeacon("catchup");
      this._publishStatus("correcting", driftMs);
      return;
    }

    if (serverState === "paused" && !this._isPaused()) {
      this._setSyncLock();
      void Promise.resolve(this.playback.pause?.()).catch(() => {});
      this.playback.seekTo?.(targetPosition);
      this._setAdaptiveBeacon("synced");
      this._publishStatus("synced", driftMs);
      return;
    }

    const syncedThreshold = this.useConservativeSync ? 1.0 : 0.1;
    const seekThreshold = this.useConservativeSync ? 3.0 : 0.5;

    if (absoluteDrift < syncedThreshold) {
      this._resetPlaybackRate();
      this._setAdaptiveBeacon("synced");
      this._publishStatus("synced", driftMs);
      return;
    }

    if (absoluteDrift > seekThreshold) {
      this._setSyncLock();
      this.playback.seekTo?.(targetPosition);
      this._resetPlaybackRate();
      this._setAdaptiveBeacon("catchup");
      this._publishStatus("correcting", driftMs);
      return;
    }

    if (this.useConservativeSync) {
      this._setAdaptiveBeacon("synced");
      this._publishStatus("synced", driftMs);
      return;
    }

    const direction = drift < 0 ? 1 : -1;
    const normalized = Math.min(1, absoluteDrift / 0.5);
    const adjustment = normalized * normalized * 0.15;
    this.playback.setPlaybackRate?.(Math.max(0.8, Math.min(1.2, 1 + direction * adjustment)));
    this._setAdaptiveBeacon("correcting");
    this._publishStatus("correcting", driftMs);

    this._clearTimer("rateResetTimer");
    this.rateResetTimer = setTimeout(() => this._resetPlaybackRate(), 3000);
  },

  _scheduleCommand(callback, delay, generation) {
    const timer = setTimeout(() => {
      this.pendingCommandTimers.delete(timer);
      if (generation === this.commandGeneration && !this.destroyedHook) callback();
    }, delay);
    this.pendingCommandTimers.add(timer);
  },

  _cancelPendingCommands() {
    this.commandGeneration += 1;
    for (const timer of this.pendingCommandTimers) clearTimeout(timer);
    this.pendingCommandTimers.clear();
  },

  _setSyncLock() {
    this.syncLock = true;
    this._clearTimer("syncLockTimeout");
    this.syncLockTimeout = setTimeout(() => {
      this.syncLock = false;
      this.syncLockTimeout = null;
    }, 1500);
  },

  _setSyncHold(held, reason = null) {
    const shouldHold = !this.isHost && held === true;
    this.syncHold = shouldHold;
    this.syncHoldReason = shouldHold ? reason : null;

    let holdApplied;
    try {
      holdApplied = this.playback?.setSyncHold?.(shouldHold);
    } catch {
      holdApplied = undefined;
    }

    if (shouldHold && holdApplied === undefined) {
      void Promise.resolve(this.playback?.pause?.()).catch(() => {});
    }
  },

  _resetPlaybackRate() {
    const currentRate = Number(this.playback?.getPlaybackRate?.());
    if (Number.isFinite(currentRate) && Math.abs(currentRate - 1) > 0.01) {
      this.playback?.setPlaybackRate?.(1);
    }
    this._clearTimer("rateResetTimer");
  },

  // Adaptive beacons

  _startBeacon() {
    if (!this.playback || !this.connectedToLiveView || this.destroyedHook) return;
    this._setAdaptiveBeacon("normal");
  },

  _stopBeacon() {
    if (this.beaconInterval) clearInterval(this.beaconInterval);
    this.beaconInterval = null;
  },

  _setAdaptiveBeacon(mode) {
    const intervals = {
      catchup: 1000,
      correcting: 2000,
      normal: 5000,
      synced: 8000,
    };
    const interval = intervals[mode] || 5000;

    if (this.beaconInterval && interval === this.currentBeaconMs) return;

    this.currentBeaconMs = interval;
    this._stopBeacon();
    if (!this.connectedToLiveView || this.destroyedHook) return;

    this.beaconInterval = setInterval(() => this._sendBeacon(), interval);
  },

  _sendBeacon({ urgent = false } = {}) {
    if (!this.playback || !this.connectedToLiveView || this.destroyedHook) return;
    if (this.syncHold && !this._isPaused()) {
      this._setSyncHold(true, this.syncHoldReason);
    }

    this._safePush("wp_sync_beacon", {
      position: this._position(),
      state: this._isPaused() ? "paused" : "playing",
      buffering: this.isBuffering,
      client_time: Date.now(),
      urgent,
    });
  },

  _handleHostStatus(data) {
    const status = data?.status;
    if (!["online", "offline"].includes(status)) return;
    this.lastHostStatus = status;

    if (!this.isHost && status === "offline") {
      this._setSyncHold(true, "host_offline");
      this._publishStatus("host_offline");
      return;
    }

    if (!this.isHost && status === "online") {
      if (this.syncHoldReason === "buffering") {
        this._setSyncHold(true, "buffering");
        this._publishStatus("buffering");
      } else {
        this._setSyncHold(true, "connecting");
        this._publishStatus("connecting");
      }

      this._estimateClockOffset();
      this._safePush("wp_request_sync", {});
    }
  },

  _publishStatus(status, driftMs = null) {
    if (!this.isHost) {
      if (this.syncHoldReason === "buffering") status = "buffering";
      if (this.syncHoldReason === "host_offline") status = "host_offline";
      if (this.syncHoldReason === "disconnected") status = "disconnected";
      if (this.syncHoldReason === "connecting") status = "connecting";
    }
    if (this.isHost && status !== "buffering" && status !== "disconnected") status = "synced";

    const numericDrift = Number(driftMs);
    const normalizedDrift =
      driftMs === null || driftMs === undefined || !Number.isFinite(numericDrift)
        ? null
        : Math.max(0, Math.round(numericDrift));
    const driftChanged =
      normalizedDrift !== null &&
      (this.lastPublishedDrift === null ||
        Math.abs(normalizedDrift - this.lastPublishedDrift) >= 100);

    this._renderStatus(status, normalizedDrift);
    if (status === this.lastPublishedStatus && !driftChanged) return;

    this.lastPublishedStatus = status;
    this.lastPublishedDrift = normalizedDrift;
    this._safePush("wp_sync_status", { status, drift_ms: normalizedDrift });
  },

  _renderStatus(status, driftMs = null) {
    const element = document.getElementById("watch-party-sync-status");
    const textElement = element?.querySelector?.("[data-sync-status-text]");
    if (!element || !textElement) return;

    textElement.textContent = this._statusText(status, driftMs);
    element.dataset.syncState = status;

    element.classList.remove(
      "bg-warning/90",
      "bg-error/90",
      "bg-brand/90",
      "bg-success/90",
      "text-black",
      "text-white",
    );

    if (status === "disconnected") {
      element.classList.add("bg-error/90", "text-white");
    } else if (["host_offline", "connecting", "correcting", "buffering"].includes(status)) {
      element.classList.add("bg-warning/90", "text-black");
    } else if (this.isHost) {
      element.classList.add("bg-brand/90", "text-white");
    } else {
      element.classList.add("bg-success/90", "text-black");
    }
  },

  _statusText(status, driftMs = null) {
    if (this.isHost) {
      if (status === "buffering") return "Aguardando o buffer";
      if (status === "disconnected") return "Sincronização desconectada";
      return "Você controla a reprodução";
    }

    switch (status) {
      case "host_offline":
        return "Anfitrião desconectado — aguardando retorno";
      case "connecting":
        return "Conectando à sincronização";
      case "correcting":
        return Number.isInteger(driftMs) && driftMs > 0
          ? `Ajustando sincronização (${driftMs} ms)`
          : "Ajustando sincronização";
      case "buffering":
        return "Aguardando o buffer";
      case "disconnected":
        return "Sincronização desconectada";
      default:
        return Number.isInteger(driftMs) && driftMs >= 100
          ? `Sincronizado com o anfitrião (${driftMs} ms)`
          : "Sincronizado com o anfitrião";
    }
  },

  _safePush(event, payload) {
    if (!this.connectedToLiveView || this.destroyedHook) return;

    try {
      const result = this.pushEvent(event, payload);
      result?.catch?.(() => {});
    } catch {
      // LiveView may be between disconnect and reconnect; lifecycle hooks recover it.
    }
  },

  // Invite copy and reactions

  async _copyInvite(event) {
    const text = event.detail?.text;
    if (typeof text !== "string" || text.length === 0) return;

    let copied = false;
    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(text);
        copied = true;
      }
    } catch {
      copied = false;
    }

    if (!copied) copied = this._legacyCopy(text);
    this._announceCopy(copied, event.target);
  },

  _legacyCopy(text) {
    try {
      const textarea = document.createElement("textarea");
      textarea.value = text;
      textarea.setAttribute("readonly", "");
      textarea.style.position = "fixed";
      textarea.style.opacity = "0";
      document.body.appendChild(textarea);
      textarea.select();
      const copied = document.execCommand?.("copy") === true;
      textarea.remove();
      return copied;
    } catch {
      return false;
    }
  },

  _announceCopy(copied, target) {
    let liveRegion = document.getElementById("watch-party-copy-status");
    if (!liveRegion) {
      liveRegion = document.createElement("span");
      liveRegion.id = "watch-party-copy-status";
      liveRegion.className = "sr-only";
      liveRegion.setAttribute("aria-live", "polite");
      document.body.appendChild(liveRegion);
    }

    liveRegion.textContent = copied
      ? "Link da Watch Party copiado."
      : "Não foi possível copiar o link.";
    const button = target?.closest?.("button");
    if (button && copied) {
      const originalLabel = button.getAttribute("aria-label");
      button.setAttribute("aria-label", "Link copiado");
      const timer = setTimeout(() => {
        this.reactionTimers.delete(timer);
        if (originalLabel) button.setAttribute("aria-label", originalLabel);
      }, 2000);
      this.reactionTimers.add(timer);
    }
  },

  _showFloatingReaction(data) {
    const container = document.getElementById("wp-reactions-container");
    if (!container || typeof data?.emoji !== "string") return;

    const element = document.createElement("div");
    element.className = "floating-reaction";
    element.textContent = data.emoji;
    element.style.left = `${Math.random() * 80}px`;
    container.appendChild(element);

    const timer = setTimeout(() => {
      this.reactionTimers.delete(timer);
      element.remove();
    }, 2000);
    this.reactionTimers.add(timer);
  },

  _clearTimer(property) {
    if (this[property]) clearTimeout(this[property]);
    this[property] = null;
  },
};

export default WatchPartySync;
