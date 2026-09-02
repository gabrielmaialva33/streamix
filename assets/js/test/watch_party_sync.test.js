import assert from "node:assert/strict";
import test from "node:test";

import WatchPartySync from "../hooks/watch_party_sync.js";

function createSyncContext({ isHost = false, dataset = {}, overrides = {} } = {}) {
  const seeks = [];
  const rates = [];
  const syncHolds = [];
  const pushes = [];
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
    el: { dataset: { isHost: String(isHost), ...dataset } },
    handleEvent() {},
    pushEvent(event, payload) {
      pushes.push({ event, payload });
    },
  });
  context._setup();
  context.playback = playback;
  context.syncHold = false;
  context.syncHoldReason = null;
  context._renderStatus = () => true;
  // Real beacon intervals would keep the test process alive; record instead.
  context.beaconModes = [];
  context._setAdaptiveBeacon = (mode) => context.beaconModes.push(mode);
  Object.assign(context, overrides);

  return { context, playback, pushes, rates, seeks, syncHolds };
}

test("_setup builds DOM-free collaborators from the element dataset", () => {
  const { context } = createSyncContext({ isHost: true, dataset: { roomId: "42" } });

  assert.equal(context.isHost, true);
  assert.equal(context.roomId, "42");
  assert.equal(context.syncLock, false);
  assert.equal(context.clockReady, false);
  assert.equal(context.commandGeneration, 0);
  for (const collaborator of ["clock", "sequencer", "commands", "beacons", "reactions"]) {
    assert.ok(context[collaborator], `${collaborator} collaborator must exist`);
  }
});

test("uses conservative drift correction for engines without rate control", () => {
  const { context, playback } = createSyncContext();

  assert.equal(context.useConservativeSync, false);

  playback.supportsPlaybackRate = () => false;
  assert.equal(context.useConservativeSync, true);

  playback.supportsPlaybackRate = () => true;
  context.nativeHlsPlayback = true;
  assert.equal(context.useConservativeSync, true);
});

test("command acceptance delegates to the sequencer with the current hold", () => {
  const { context } = createSyncContext();

  assert.equal(context._acceptCommand({ sequence: 4, server_time: 100 }), true);
  assert.equal(context._acceptCommand({ sequence: 4, server_time: 101 }), false);

  context.syncHold = true;
  assert.equal(context._acceptCommand({ sequence: 4, type: "sync" }), true);
  assert.equal(context._acceptCommand({ sequence: 4, type: "play" }), false);
});

test("does not extrapolate a server timestamp before clock calibration completes", () => {
  const { context, seeks } = createSyncContext({
    overrides: { _serverNow: () => 10_000, _setAdaptiveBeacon() {}, _publishStatus() {} },
  });

  context._correctDrift(10, "playing", 0);
  assert.deepEqual(seeks, []);

  context.clock.ready = true;
  context._correctDrift(10, "playing", 0);
  assert.deepEqual(seeks, [20]);
});

test("drift nudges the playback rate and schedules its reset", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const beacons = [];
  const statuses = [];
  const { context, rates } = createSyncContext({
    overrides: {
      _setAdaptiveBeacon: (mode) => beacons.push(mode),
      _publishStatus: (status, drift) => statuses.push([status, drift]),
    },
  });

  context._correctDrift(9.7, "playing", null);
  assert.equal(rates.length, 1);
  assert.ok(rates[0] < 1);
  assert.deepEqual(beacons, ["correcting"]);
  assert.deepEqual(statuses, [["correcting", 300]]);

  context.playback.getPlaybackRate = () => rates[0];
  t.mock.timers.tick(3_000);
  assert.deepEqual(rates.at(-1), 1, "rate resets after the nudge window");
});

test("disconnect cancels delayed commands, clock work, beacons, and rate correction", () => {
  const calls = [];
  const { context } = createSyncContext({
    overrides: {
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
    overrides: {
      _estimateClockOffset() {},
      _publishStatus(status) {
        statuses.push(status);
      },
      _safePush(event, payload) {
        requests.push({ event, payload });
      },
    },
  });
  context.syncHold = true;
  context.syncHoldReason = "buffering";

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
    overrides: {
      _isPaused: () => false,
      _safePush(event, payload) {
        pushes.push({ event, payload });
      },
    },
  });
  context.syncHold = true;
  context.syncHoldReason = "host_offline";

  context._sendBeacon({ urgent: true });

  assert.deepEqual(syncHolds, [true]);
  assert.equal(pushes[0].event, "wp_sync_beacon");
  assert.equal(pushes[0].payload.urgent, true);
});

test("buffering transitions publish an urgent beacon so throttling cannot hide state changes", () => {
  const beacons = [];
  const statuses = [];
  const { context } = createSyncContext({
    overrides: {
      _publishStatus(status) {
        statuses.push(status);
      },
      _sendBeacon(options) {
        beacons.push(options);
      },
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

  const host = createSyncContext({ isHost: true }).context;
  assert.equal(host._statusText("synced"), "Você controla a reprodução");
  assert.equal(host._statusText("buffering"), "Aguardando o buffer");
});

test("reapplies a deduplicated status locally while pushing it to LiveView only once", () => {
  const renders = [];
  const { context, pushes } = createSyncContext();
  context._renderStatus = (status, drift) => renders.push({ drift, status });

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

test("drift publication is throttled to 100 ms steps", () => {
  const { context, pushes } = createSyncContext();

  context._publishStatus("synced", 40);
  context._publishStatus("synced", 90);
  context._publishStatus("synced", 160);

  assert.deepEqual(
    pushes.map((push) => push.payload.drift_ms),
    [40, 160],
  );
});

test("host buffering holds a viewer until a later authoritative command releases it", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const statuses = [];
  const { context, syncHolds } = createSyncContext({
    overrides: {
      _publishStatus(status) {
        statuses.push(status);
      },
      _setAdaptiveBeacon() {},
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
  assert.equal(context.syncLock, true);
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
  const { context, pushes } = createSyncContext();
  context.syncHold = true;
  context.syncHoldReason = "buffering";
  context._renderStatus = (status) => rendered.push(status);

  context._publishStatus("correcting");

  assert.deepEqual(rendered, ["buffering"]);
  assert.deepEqual(
    pushes.map((push) => push.payload.status),
    ["buffering"],
  );
});

test("a host-status DOM snapshot pauses a viewer even when the push event is lost", () => {
  const statuses = [];
  const { context, syncHolds } = createSyncContext({
    dataset: { hostStatus: "offline" },
    overrides: {
      _publishStatus(status) {
        statuses.push(status);
      },
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
  const { context, pushes, syncHolds } = createSyncContext();
  context.lastHostStatus = "offline";
  context.sequencer.lastSequence = 7;
  context.syncHold = true;
  context.syncHoldReason = "host_offline";
  context._renderStatus = (status) => rendered.push(status);

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
  assert.deepEqual(
    pushes.map((push) => push.payload.status),
    ["host_offline"],
  );
});

test("delayed host actions honour the calibrated clock and stale generations", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { context, seeks } = createSyncContext({
    overrides: { _publishStatus() {}, _setAdaptiveBeacon() {} },
  });
  context.clock.ready = true;
  context._serverNow = () => 5_000;

  context._handleSyncCommand({ type: "seek", position: 30, sequence: 1, target_time: 5_400 });
  assert.deepEqual(seeks, [], "the seek waits for the target time");
  t.mock.timers.tick(399);
  assert.deepEqual(seeks, []);
  t.mock.timers.tick(1);
  assert.deepEqual(seeks, [30]);

  context._handleSyncCommand({ type: "seek", position: 50, sequence: 2, target_time: 5_400 });
  context._cancelPendingCommands();
  t.mock.timers.tick(1_000);
  assert.deepEqual(seeks, [30], "cancelled generations never apply");
});

test("LiveView updates rebind the player and apply host state before playback", () => {
  const calls = [];
  const { context } = createSyncContext({
    overrides: {
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
    },
  });

  context.updated();

  assert.deepEqual(calls, ["bind", "host", "snapshot"]);
});

test("rejects invalid action positions before taking the sync lock", () => {
  const { context, seeks } = createSyncContext();

  context._applyActionCommand({ position: "invalid", type: "seek" }, 0);

  assert.equal(context.syncLock, false);
  assert.deepEqual(seeks, []);
});

test("accessors stay live after LiveView copies the hook definition onto an instance", () => {
  // Mirrors phoenix_live_view's ViewHook: `this[key] = callbacks[key]` for
  // every own property, which snapshots prototype getters into plain values.
  const instance = {
    el: { dataset: { isHost: "false" } },
    handleEvent() {},
    pushEvent() {},
  };
  for (const key of Object.keys(WatchPartySync)) instance[key] = WatchPartySync[key];

  instance._setup();
  assert.equal(instance.playback, null);
  const bridge = {
    getCurrentTime: () => 3,
    isPaused: () => true,
    supportsPlaybackRate: () => false,
  };
  instance.binding.playback = bridge;
  assert.equal(instance.playback, bridge, "playback reads through to the binding");
  assert.equal(instance.useConservativeSync, true, "conservative sync follows the live bridge");

  instance.playback = null;
  assert.equal(instance.binding.playback, null, "the setter writes through");

  assert.equal(instance.commandGeneration, 0);
  instance.commands.cancelAll();
  assert.equal(instance.commandGeneration, 1, "generation is read live from the scheduler");

  instance.commands.lock();
  assert.equal(instance.syncLock, true);
  instance.commands.unlock();
  assert.equal(instance.syncLock, false);

  instance.clock.ready = true;
  assert.equal(instance.clockReady, true);
});
