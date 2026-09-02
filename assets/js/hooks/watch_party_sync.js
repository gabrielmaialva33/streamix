import { PLAYBACK_BRIDGE_EVENT } from "../player/playback_bridge.js";
import { createBeaconScheduler } from "../watch_party/beacon_scheduler.js";
import { createClockSync } from "../watch_party/clock_sync.js";
import { createSyncCommandScheduler } from "../watch_party/command_scheduler.js";
import { createCommandSequencer } from "../watch_party/command_sequencer.js";
import {
  DRIFT_ACTION,
  driftThresholds,
  RATE_RESET_DELAY_MS,
  resolveDriftCorrection,
} from "../watch_party/drift_policy.js";
import { createReactionPresenter } from "../watch_party/reactions.js";
import {
  driftChanged,
  normalizeDriftMs,
  renderSyncStatus,
  resolveSyncStatus,
  syncStatusText,
} from "../watch_party/sync_status.js";

const PLAYER_READY_EVENT = "streamix:playback-ready";
const BUFFERING_EVENT = "streamix:buffering";
const MAX_ACTION_DELAY_MS = 1500;
const PLAYER_POLL_FAST_ATTEMPTS = 50;
const SYNC_STATUS_ELEMENT_ID = "watch-party-sync-status";

/**
 * Watch Party sync hook: composition root for the viewer/host sync loop.
 *
 * Clock estimation, command ordering, delayed command scheduling, drift policy,
 * status vocabulary, beacon cadence and reaction/copy presentation live in
 * `assets/js/watch_party/`. The hook owns LiveView transport, the player
 * bridge binding and the durable hold state.
 */
const WatchPartySync = {
  mounted() {
    this._setup();
    this.el.__watchPartySyncHook = this;

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

  // DOM-free state and collaborators. Tests build a hook context and call this
  // directly; `mounted()` adds the document and window listeners on top.
  _setup() {
    this.isHost = this.el?.dataset?.isHost === "true";
    this.roomId = this.el?.dataset?.roomId;
    this.connectedToLiveView = true;
    this.destroyedHook = false;
    this.playerEl = null;
    this.videoEl = null;
    this.playback = null;
    this.playerWaitTimer = null;
    this.rateResetTimer = null;
    this.syncHold = !this.isHost;
    this.syncHoldReason = this.isHost ? null : "connecting";
    this.isBuffering = false;
    this.nativeHlsPlayback = false;
    this.lastHostStatus = null;
    this.lastPublishedStatus = null;
    this.lastPublishedDrift = null;

    this.clock = createClockSync({ push: (event, payload) => this._safePush(event, payload) });
    this.sequencer = createCommandSequencer();
    this.commands = createSyncCommandScheduler();
    this.beacons = createBeaconScheduler({ send: () => this._sendBeacon() });
    this.reactions = createReactionPresenter();
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
    this.beacons?.destroy();
    this.commands?.destroy();
    this._clearClockTimers();
    this._clearTimer("playerWaitTimer");
    this._clearTimer("rateResetTimer");
    this._setSyncHold(false);
    this._unbindPlayer();
    this.reactions?.destroy();

    document.removeEventListener(PLAYER_READY_EVENT, this._onPlaybackReady);
    document.removeEventListener("visibilitychange", this._visibilityHandler);
    window.removeEventListener("phx:copy", this._copyHandler);
    if (this.el?.__watchPartySyncHook === this) delete this.el.__watchPartySyncHook;
  },

  get useConservativeSync() {
    return this.nativeHlsPlayback || this.playback?.supportsPlaybackRate?.() === false;
  },

  get syncLock() {
    return this.commands?.locked === true;
  },

  get clockReady() {
    return this.clock?.ready === true;
  },

  get commandGeneration() {
    return this.commands?.generation ?? 0;
  },

  // Player binding

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
    this.clock.estimate();
  },

  _handleClockPong(data) {
    this.clock.handlePong(data);
  },

  _serverNow() {
    return this.clock.serverNow();
  },

  _clearClockTimers() {
    this.clock?.cancel();
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
    return this.sequencer.accept(command, { holding: this.syncHold });
  },

  _applyActionCommand(command, generation) {
    if (!this.playback || !this.commands.isCurrent(generation) || this.destroyedHook) return;

    const targetPosition = Number(command.position);
    if (!Number.isFinite(targetPosition) || targetPosition < 0) return;
    this._setSyncLock();

    switch (command.type) {
      case "play": {
        const driftThreshold = driftThresholds(this.useConservativeSync).play;
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
    const correction = resolveDriftCorrection({
      clockReady: this.clockReady,
      conservative: this.useConservativeSync,
      currentPosition: this._position(),
      paused: this._isPaused(),
      serverNow: this._serverNow(),
      serverPosition,
      serverState,
      serverTime,
    });
    if (!correction) return;

    const { action, beacon, driftMs, lock, rate, seek, status, targetPosition } = correction;
    if (lock) this._setSyncLock();

    switch (action) {
      case DRIFT_ACTION.RESUME:
        void Promise.resolve(this.playback.play?.()).catch(() => {});
        if (seek) this.playback.seekTo?.(targetPosition);
        break;
      case DRIFT_ACTION.PAUSE:
        void Promise.resolve(this.playback.pause?.()).catch(() => {});
        this.playback.seekTo?.(targetPosition);
        break;
      case DRIFT_ACTION.SYNCED:
        this._resetPlaybackRate();
        break;
      case DRIFT_ACTION.SEEK:
        this.playback.seekTo?.(targetPosition);
        this._resetPlaybackRate();
        break;
      case DRIFT_ACTION.HOLD:
        break;
      case DRIFT_ACTION.NUDGE:
        this.playback.setPlaybackRate?.(rate);
        this._clearTimer("rateResetTimer");
        this.rateResetTimer = setTimeout(() => this._resetPlaybackRate(), RATE_RESET_DELAY_MS);
        break;
    }

    this._setAdaptiveBeacon(beacon);
    this._publishStatus(status, driftMs);
  },

  _scheduleCommand(callback, delay, generation = this.commandGeneration) {
    if (!this.commands.isCurrent(generation)) return;
    this.commands.schedule(() => {
      if (!this.destroyedHook) callback();
    }, delay);
  },

  _cancelPendingCommands() {
    this.commands.cancelAll();
  },

  _setSyncLock() {
    this.commands.lock();
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
    this.beacons?.stop();
  },

  _setAdaptiveBeacon(mode) {
    this.beacons.setMode(mode, { active: this.connectedToLiveView && !this.destroyedHook });
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

  // Status

  _publishStatus(status, driftMs = null) {
    const resolved = resolveSyncStatus({
      holdReason: this.syncHoldReason,
      isHost: this.isHost,
      status,
    });
    const normalizedDrift = normalizeDriftMs(driftMs);

    this._renderStatus(resolved, normalizedDrift);
    if (
      resolved === this.lastPublishedStatus &&
      !driftChanged(this.lastPublishedDrift, normalizedDrift)
    ) {
      return;
    }

    this.lastPublishedStatus = resolved;
    this.lastPublishedDrift = normalizedDrift;
    this._safePush("wp_sync_status", { status: resolved, drift_ms: normalizedDrift });
  },

  _renderStatus(status, driftMs = null) {
    const element = document.getElementById(SYNC_STATUS_ELEMENT_ID);
    return renderSyncStatus(element, { driftMs, isHost: this.isHost, status });
  },

  _statusText(status, driftMs = null) {
    return syncStatusText({ driftMs, isHost: this.isHost, status });
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

  _copyInvite(event) {
    return this.reactions.copyInvite(event);
  },

  _showFloatingReaction(data) {
    return this.reactions.showFloatingReaction(data);
  },

  _clearTimer(property) {
    if (this[property]) clearTimeout(this[property]);
    this[property] = null;
  },
};

export default WatchPartySync;
