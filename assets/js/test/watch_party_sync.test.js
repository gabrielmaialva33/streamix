import assert from "node:assert/strict";
import test from "node:test";

import WatchPartySync from "../hooks/watch_party_sync.js";

function createSyncContext(overrides = {}) {
  const seeks = [];
  const rates = [];
  const syncHolds = [];
  const playback = {
    engine: "native",
    getCurrentTime: () => 10,
    getPlaybackRate: () => 1,
    isPaused: () => false,
    pause: () => true,
    play: () => true,
    seekTo(position) {
      seeks.push(position);
      return true;
    },
    setPlaybackRate(rate) {
      rates.push(rate);
      return true;
    },
    setSyncHold(held) {
      syncHolds.push(held);
      return true;
    },
    supportsPlaybackRate: () => true,
  };

  const context = Object.assign(Object.create(WatchPartySync), {
    beaconInterval: null,
    clockOffset: 0,
    clockPingTimer: null,
    clockPings: new Map(),
    clockReady: false,
    commandGeneration: 0,
    connectedToLiveView: true,
    currentBeaconMs: null,
    destroyedHook: false,
    isHost: false,
    lastHostStatus: null,
    lastPublishedDrift: null,
    lastPublishedStatus: null,
    lastServerCommandTime: 0,
    lastServerSequence: 0,
    nativeHlsPlayback: false,
    pendingCommandTimers: new Set(),
    playback,
    rateResetTimer: null,
    syncHold: false,
    syncHoldReason: null,
    syncLock: false,
    syncLockTimeout: null,
    _publishStatus() {},
    _setAdaptiveBeacon() {},
    ...overrides,
  });

  return { context, playback, rates, seeks, syncHolds };
}

test("uses conservative drift correction for engines without rate control", () => {
  const { context, playback } = createSyncContext();

  assert.equal(context.useConservativeSync, false);

  playback.supportsPlaybackRate = () => false;
  assert.equal(context.useConservativeSync, true);

  playback.supportsPlaybackRate = () => true;
  context.nativeHlsPlayback = true;
  assert.equal(context.useConservativeSync, true);
});

test("orders commands by monotonic room sequence before falling back to server time", () => {
  const { context } = createSyncContext();

  assert.equal(context._acceptCommand({ sequence: 4, server_time: 100 }), true);
  assert.equal(context._acceptCommand({ sequence: 4, server_time: 101 }), false);
  assert.equal(context._acceptCommand({ sequence: 3, server_time: 102 }), false);
  assert.equal(context._acceptCommand({ sequence: 5, server_time: 99 }), true);

  context.syncHold = true;
  assert.equal(context._acceptCommand({ sequence: 5, server_time: 100, type: "sync" }), true);
  assert.equal(context._acceptCommand({ sequence: 5, server_time: 101, type: "play" }), false);

  const legacy = createSyncContext().context;
  assert.equal(legacy._acceptCommand({ server_time: 200 }), true);
  assert.equal(legacy._acceptCommand({ server_time: 200 }), false);
  assert.equal(legacy._acceptCommand({ server_time: 201 }), true);
});

test("does not extrapolate a server timestamp before clock calibration completes", () => {
  const { context, seeks } = createSyncContext({
    _serverNow: () => 10_000,
  });

  context._correctDrift(10, "playing", 0);
  assert.deepEqual(seeks, []);

  context.clockReady = true;
  context._correctDrift(10, "playing", 0);
  assert.deepEqual(seeks, [20]);
});

test("disconnect cancels delayed commands, clock work, beacons, and rate correction", () => {
  const calls = [];
  const { context } = createSyncContext({
    _cancelPendingCommands() {
      calls.push("commands");
    },
    _clearClockTimers() {
      calls.push("clock");
    },
    _publishStatus(status) {
      calls.push(`status:${status}`);
    },
    _resetPlaybackRate() {
      calls.push("rate");
    },
    _stopBeacon() {
      calls.push("beacon");
    },
  });

  context.disconnected();

  assert.equal(context.connectedToLiveView, false);
  assert.equal(context.syncHold, true);
  assert.equal(context.syncHoldReason, "disconnected");
  assert.deepEqual(calls, ["beacon", "commands", "clock", "rate", "status:disconnected"]);
});

test("host online preserves a buffering hold until an authoritative snapshot arrives", () => {
  const statuses = [];
  const requests = [];
  const { context, syncHolds } = createSyncContext({
    syncHold: true,
    syncHoldReason: "buffering",
    _estimateClockOffset() {},
    _publishStatus(status) {
      statuses.push(status);
    },
    _safePush(event, payload) {
      requests.push({ event, payload });
    },
  });

  context._handleHostStatus({ status: "online" });

  assert.equal(context.syncHold, true);
  assert.equal(context.syncHoldReason, "buffering");
  assert.deepEqual(syncHolds, [true]);
  assert.deepEqual(statuses, ["buffering"]);
  assert.deepEqual(requests, [{ event: "wp_request_sync", payload: {} }]);
});

test("beacons reapply a durable hold when an engine resumes behind the hook", () => {
  const pushes = [];
  const { context, syncHolds } = createSyncContext({
    syncHold: true,
    syncHoldReason: "host_offline",
    _isPaused: () => false,
    _safePush(event, payload) {
      pushes.push({ event, payload });
    },
  });

  context._sendBeacon({ urgent: true });

  assert.deepEqual(syncHolds, [true]);
  assert.equal(pushes[0].event, "wp_sync_beacon");
  assert.equal(pushes[0].payload.urgent, true);
});

test("buffering transitions publish an urgent beacon so throttling cannot hide state changes", () => {
  const beacons = [];
  const statuses = [];
  const { context } = createSyncContext({
    isBuffering: false,
    _publishStatus(status) {
      statuses.push(status);
    },
    _sendBeacon(options) {
      beacons.push(options);
    },
  });

  context._setBuffering(true);
  context._setBuffering(true);
  context._setBuffering(false);

  assert.deepEqual(beacons, [{ urgent: true }, { urgent: true }, { urgent: true }]);
  assert.deepEqual(statuses, ["buffering", "correcting"]);
});

test("formats status labels without waiting for a LiveView round trip", () => {
  const viewer = createSyncContext().context;

  assert.equal(viewer._statusText("buffering"), "Aguardando o buffer");
  assert.equal(viewer._statusText("correcting", 240), "Ajustando sincronização (240 ms)");
  assert.equal(viewer._statusText("synced", 150), "Sincronizado com o anfitrião (150 ms)");
  assert.equal(viewer._statusText("host_offline"), "Anfitrião desconectado — aguardando retorno");

  viewer.isHost = true;
  assert.equal(viewer._statusText("synced"), "Você controla a reprodução");
  assert.equal(viewer._statusText("buffering"), "Aguardando o buffer");
});

test("reapplies a deduplicated status locally while pushing it to LiveView only once", () => {
  const renders = [];
  const pushes = [];
  const { context } = createSyncContext();
  delete context._publishStatus;
  context._renderStatus = (status, drift) => renders.push({ drift, status });
  context._safePush = (event, payload) => pushes.push({ event, payload });

  context._publishStatus("buffering");
  context._publishStatus("buffering");

  assert.deepEqual(renders, [
    { drift: null, status: "buffering" },
    { drift: null, status: "buffering" },
  ]);
  assert.deepEqual(pushes, [
    { event: "wp_sync_status", payload: { drift_ms: null, status: "buffering" } },
  ]);
});

test("host buffering holds a viewer until a later authoritative command releases it", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const statuses = [];
  const { context, syncHolds } = createSyncContext({
    _publishStatus(status) {
      statuses.push(status);
    },
  });

  context._handleSyncCommand({
    host_buffering: true,
    position: 10,
    sequence: 1,
    server_time: 100,
    state: "playing",
    type: "sync",
  });

  assert.equal(context.syncHold, true);
  assert.equal(context.syncHoldReason, "buffering");
  assert.deepEqual(syncHolds, [true]);
  assert.deepEqual(statuses, ["buffering"]);

  context._handleSyncCommand({
    host_buffering: false,
    position: 10,
    sequence: 2,
    server_time: 101,
    state: "paused",
    type: "sync",
  });

  assert.equal(context.syncHold, false);
  assert.equal(context.syncHoldReason, null);
  assert.deepEqual(syncHolds, [true, false]);
});

test("buffering hold keeps the visible sync status stable through local media events", () => {
  const rendered = [];
  const pushed = [];
  const { context } = createSyncContext({
    syncHold: true,
    syncHoldReason: "buffering",
  });
  delete context._publishStatus;
  context._renderStatus = (status) => rendered.push(status);
  context._safePush = (_event, payload) => pushed.push(payload.status);

  context._publishStatus("correcting");

  assert.deepEqual(rendered, ["buffering"]);
  assert.deepEqual(pushed, ["buffering"]);
});

test("a host-status DOM snapshot pauses a viewer even when the push event is lost", () => {
  const statuses = [];
  const { context, syncHolds } = createSyncContext({
    el: { dataset: { hostStatus: "offline" } },
    _publishStatus(status) {
      statuses.push(status);
    },
  });

  context._applyHostSnapshot();
  context._applyHostSnapshot();

  assert.equal(context.lastHostStatus, "offline");
  assert.equal(context.syncHoldReason, "host_offline");
  assert.deepEqual(syncHolds, [true]);
  assert.deepEqual(statuses, ["host_offline"]);
});

test("an offline host cannot be released by a same-version playback snapshot", () => {
  const rendered = [];
  const pushed = [];
  const { context, syncHolds } = createSyncContext({
    lastHostStatus: "offline",
    lastServerSequence: 7,
    syncHold: true,
    syncHoldReason: "host_offline",
  });
  delete context._publishStatus;
  context._renderStatus = (status) => rendered.push(status);
  context._safePush = (_event, payload) => pushed.push(payload.status);

  context._handleSyncCommand({
    host_buffering: false,
    position: 10,
    sequence: 7,
    server_time: 100,
    state: "paused",
    type: "sync",
  });

  assert.equal(context.syncHold, true);
  assert.equal(context.syncHoldReason, "host_offline");
  assert.deepEqual(syncHolds, [true]);
  assert.deepEqual(rendered, ["host_offline"]);
  assert.deepEqual(pushed, ["host_offline"]);
});

test("LiveView updates rebind the player and apply host state before playback", () => {
  const calls = [];
  const { context } = createSyncContext({
    lastPublishedStatus: null,
    _applyHostSnapshot() {
      calls.push("host");
    },
    _applyServerSnapshot() {
      calls.push("snapshot");
    },
    _ensurePlayerBinding() {
      calls.push("bind");
      return true;
    },
  });

  context.updated();

  assert.deepEqual(calls, ["bind", "host", "snapshot"]);
});

test("rejects invalid action positions before taking the sync lock", () => {
  let locks = 0;
  const { context, seeks } = createSyncContext({
    _setSyncLock() {
      locks += 1;
    },
  });

  context._applyActionCommand({ position: "invalid", type: "seek" }, 0);

  assert.equal(locks, 0);
  assert.deepEqual(seeks, []);
});
