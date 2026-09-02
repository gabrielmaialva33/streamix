import assert from "node:assert/strict";
import test from "node:test";

import { BEACON_INTERVALS_MS, createBeaconScheduler } from "../watch_party/beacon_scheduler.js";
import { CLOCK_PING_ATTEMPTS, createClockSync } from "../watch_party/clock_sync.js";
import { createSyncCommandScheduler, SYNC_LOCK_MS } from "../watch_party/command_scheduler.js";
import { createCommandSequencer } from "../watch_party/command_sequencer.js";
import {
  DRIFT_ACTION,
  driftThresholds,
  playbackRateForDrift,
  resolveDriftCorrection,
} from "../watch_party/drift_policy.js";
import { createReactionPresenter } from "../watch_party/reactions.js";
import {
  driftChanged,
  normalizeDriftMs,
  renderSyncStatus,
  resolveSyncStatus,
  SYNC_STATUS,
  syncStatusClasses,
  syncStatusText,
} from "../watch_party/sync_status.js";

function createTimerApi() {
  const timers = new Map();
  const intervals = new Map();
  let nextId = 1;
  return {
    setTimeout(callback, delay) {
      const id = nextId++;
      timers.set(id, { callback, delay });
      return id;
    },
    clearTimeout(id) {
      timers.delete(id);
    },
    setInterval(callback, delay) {
      const id = nextId++;
      intervals.set(id, { callback, delay });
      return id;
    },
    clearInterval(id) {
      intervals.delete(id);
    },
    pendingTimeouts: () => [...timers.values()].map((timer) => timer.delay),
    pendingIntervals: () => [...intervals.values()].map((timer) => timer.delay),
    fireTimeout(delay) {
      for (const [id, timer] of [...timers.entries()]) {
        if (timer.delay !== delay) continue;
        timers.delete(id);
        timer.callback();
      }
    },
    fireAllTimeouts() {
      for (const [id, timer] of [...timers.entries()]) {
        timers.delete(id);
        timer.callback();
      }
    },
    tickIntervals() {
      for (const timer of intervals.values()) timer.callback();
    },
  };
}

test("clock sync pings a bounded burst, keeps the best samples and exposes server time", () => {
  const pushes = [];
  const timerApi = createTimerApi();
  let now = 1_000;
  const clock = createClockSync({
    push: (event, payload) => pushes.push([event, payload]),
    now: () => now,
    timerApi,
  });

  clock.estimate();
  assert.deepEqual(pushes, [["wp_clock_ping", { id: 1, client_time: 1_000 }]]);

  const answer = (id, serverTime, rtt) => {
    now += rtt;
    clock.handlePong({ id, server_time: serverTime });
    timerApi.fireTimeout(200);
  };
  answer(1, 900, 40);
  answer(2, 900, 800);
  answer(3, 1_200, 20);
  answer(4, 1_400, 30);
  answer(5, 1_500, 1_500);

  assert.equal(pushes.length, CLOCK_PING_ATTEMPTS);
  assert.equal(clock.ready, true);
  assert.equal(clock.snapshot().samples, 4, "samples above 1s RTT are discarded");
  assert.equal(clock.serverNow(), now - clock.offset);
  assert.equal(clock.handlePong({ id: 99, server_time: 1 }), false);

  const timedOut = createClockSync({ push: () => {}, timerApi });
  timedOut.estimate();
  timerApi.fireTimeout(2_000);
  assert.deepEqual(timerApi.pendingTimeouts(), [200], "a lost pong schedules the next ping");
  timedOut.cancel();
  assert.deepEqual(timerApi.pendingTimeouts(), []);
  assert.equal(timedOut.compute(), false, "no samples means no offset");
});

test("command sequencer orders by room sequence, then by server time for legacy payloads", () => {
  const sequencer = createCommandSequencer();

  assert.equal(sequencer.accept({ sequence: 4, server_time: 100 }), true);
  assert.equal(sequencer.accept({ sequence: 4, server_time: 101 }), false);
  assert.equal(sequencer.accept({ sequence: 3, server_time: 102 }), false);
  assert.equal(sequencer.accept({ sequence: 5, server_time: 99 }), true);
  assert.equal(sequencer.accept({ sequence: 5, type: "sync" }, { holding: true }), true);
  assert.equal(sequencer.accept({ sequence: 5, type: "play" }, { holding: true }), false);
  assert.deepEqual(sequencer.snapshot(), { lastSequence: 5, lastServerTime: 0 });

  const legacy = createCommandSequencer();
  assert.equal(legacy.accept({ server_time: 200 }), true);
  assert.equal(legacy.accept({ server_time: 200 }), false);
  assert.equal(legacy.accept({ server_time: 201 }), true);
  assert.equal(legacy.accept({}), true, "payloads without ordering data are accepted");
});

test("command scheduler drops stale generations and expires the sync lock", () => {
  const timerApi = createTimerApi();
  const scheduler = createSyncCommandScheduler({ timerApi });
  const runs = [];

  const generation = scheduler.schedule(() => runs.push("first"), 100);
  scheduler.schedule(() => runs.push("second"), 300);
  assert.equal(scheduler.isCurrent(generation), true);

  scheduler.cancelAll();
  assert.equal(scheduler.isCurrent(generation), false);
  timerApi.fireAllTimeouts();
  assert.deepEqual(runs, [], "cancelled generations never run");

  scheduler.schedule(() => runs.push("third"), 50);
  timerApi.fireTimeout(50);
  assert.deepEqual(runs, ["third"]);

  scheduler.lock();
  assert.equal(scheduler.locked, true);
  assert.deepEqual(timerApi.pendingTimeouts(), [SYNC_LOCK_MS]);
  timerApi.fireTimeout(SYNC_LOCK_MS);
  assert.equal(scheduler.locked, false);

  scheduler.lock();
  scheduler.destroy();
  assert.equal(scheduler.locked, false);
  assert.deepEqual(timerApi.pendingTimeouts(), []);
});

test("drift policy resolves every viewer reaction from the host state", () => {
  assert.deepEqual(driftThresholds(false), { play: 0.3, synced: 0.1, seek: 0.5 });
  assert.deepEqual(driftThresholds(true), { play: 1.0, synced: 1.0, seek: 3.0 });

  assert.equal(resolveDriftCorrection({ serverPosition: -1, serverState: "playing" }), null);
  assert.equal(resolveDriftCorrection({ serverPosition: 1, serverState: "stopped" }), null);

  const resume = resolveDriftCorrection({
    currentPosition: 10,
    paused: true,
    serverPosition: 10,
    serverState: "playing",
    serverTime: 0,
    serverNow: 10_000,
    clockReady: true,
  });
  assert.equal(resume.action, DRIFT_ACTION.RESUME);
  assert.equal(resume.targetPosition, 20, "clock-ready viewers extrapolate elapsed time");
  assert.equal(resume.seek, true);
  assert.equal(resume.status, "correcting");

  const notExtrapolated = resolveDriftCorrection({
    currentPosition: 10,
    paused: true,
    serverPosition: 10,
    serverState: "playing",
    serverTime: 0,
    serverNow: 10_000,
    clockReady: false,
  });
  assert.equal(notExtrapolated.targetPosition, 10);
  assert.equal(notExtrapolated.seek, false);

  const pause = resolveDriftCorrection({
    currentPosition: 12,
    paused: false,
    serverPosition: 10,
    serverState: "paused",
  });
  assert.equal(pause.action, DRIFT_ACTION.PAUSE);
  assert.equal(pause.seek, true);
  assert.equal(pause.beacon, "synced");

  const synced = resolveDriftCorrection({
    currentPosition: 10.05,
    paused: false,
    serverPosition: 10,
    serverState: "playing",
  });
  assert.equal(synced.action, DRIFT_ACTION.SYNCED);
  assert.equal(synced.driftMs, 50);

  const seek = resolveDriftCorrection({
    currentPosition: 11,
    paused: false,
    serverPosition: 10,
    serverState: "playing",
  });
  assert.equal(seek.action, DRIFT_ACTION.SEEK);
  assert.equal(seek.lock, true);

  const nudge = resolveDriftCorrection({
    currentPosition: 10.3,
    paused: false,
    serverPosition: 10,
    serverState: "playing",
  });
  assert.equal(nudge.action, DRIFT_ACTION.NUDGE);
  assert.ok(Math.abs(nudge.rate - playbackRateForDrift(0.3)) < 1e-9);
  assert.ok(nudge.rate < 1, "ahead of the host slows down");

  const hold = resolveDriftCorrection({
    currentPosition: 12,
    paused: false,
    serverPosition: 10,
    serverState: "playing",
    conservative: true,
  });
  assert.equal(hold.action, DRIFT_ACTION.HOLD);
  assert.equal(hold.status, "synced");

  assert.equal(playbackRateForDrift(-5), 1.15);
  assert.equal(playbackRateForDrift(5), 0.85);
});

test("sync status precedence, drift publication and labels", () => {
  assert.equal(
    resolveSyncStatus({ isHost: false, holdReason: "buffering", status: "correcting" }),
    "buffering",
  );
  assert.equal(
    resolveSyncStatus({ isHost: false, holdReason: "host_offline", status: "synced" }),
    "host_offline",
  );
  assert.equal(
    resolveSyncStatus({ isHost: false, holdReason: null, status: "correcting" }),
    "correcting",
  );
  assert.equal(
    resolveSyncStatus({ isHost: true, holdReason: "buffering", status: "correcting" }),
    "synced",
  );
  assert.equal(resolveSyncStatus({ isHost: true, status: "buffering" }), "buffering");
  assert.equal(resolveSyncStatus({ isHost: true, status: "disconnected" }), "disconnected");

  assert.equal(normalizeDriftMs(null), null);
  assert.equal(normalizeDriftMs("abc"), null);
  assert.equal(normalizeDriftMs(-4), 0);
  assert.equal(normalizeDriftMs(149.6), 150);
  assert.equal(driftChanged(null, 50), true);
  assert.equal(driftChanged(50, 120), false);
  assert.equal(driftChanged(50, 160), true);
  assert.equal(driftChanged(50, null), false);

  assert.equal(syncStatusText({ status: "buffering" }), "Aguardando o buffer");
  assert.equal(
    syncStatusText({ status: "correcting", driftMs: 240 }),
    "Ajustando sincronização (240 ms)",
  );
  assert.equal(
    syncStatusText({ status: "synced", driftMs: 150 }),
    "Sincronizado com o anfitrião (150 ms)",
  );
  assert.equal(syncStatusText({ status: "synced", driftMs: 20 }), "Sincronizado com o anfitrião");
  assert.equal(
    syncStatusText({ status: "host_offline" }),
    "Anfitrião desconectado — aguardando retorno",
  );
  assert.equal(syncStatusText({ isHost: true, status: "synced" }), "Você controla a reprodução");
  assert.equal(syncStatusText({ isHost: true, status: "buffering" }), "Aguardando o buffer");

  assert.deepEqual(syncStatusClasses({ status: SYNC_STATUS.DISCONNECTED }), [
    "bg-error/90",
    "text-white",
  ]);
  assert.deepEqual(syncStatusClasses({ status: SYNC_STATUS.CORRECTING }), [
    "bg-warning/90",
    "text-black",
  ]);
  assert.deepEqual(syncStatusClasses({ isHost: true, status: SYNC_STATUS.SYNCED }), [
    "bg-brand/90",
    "text-white",
  ]);
  assert.deepEqual(syncStatusClasses({ status: SYNC_STATUS.SYNCED }), [
    "bg-success/90",
    "text-black",
  ]);
});

test("renderSyncStatus updates the badge only when it exists", () => {
  const classes = new Set(["bg-brand/90", "text-white"]);
  const textElement = { textContent: "" };
  const element = {
    dataset: {},
    classList: {
      add: (...names) => {
        for (const name of names) classes.add(name);
      },
      remove: (...names) => {
        for (const name of names) classes.delete(name);
      },
    },
    querySelector: (selector) => (selector === "[data-sync-status-text]" ? textElement : null),
  };

  assert.equal(renderSyncStatus(element, { status: "correcting", driftMs: 300 }), true);
  assert.equal(textElement.textContent, "Ajustando sincronização (300 ms)");
  assert.equal(element.dataset.syncState, "correcting");
  assert.deepEqual([...classes].sort(), ["bg-warning/90", "text-black"]);
  assert.equal(renderSyncStatus(null, { status: "synced" }), false);
});

test("beacon scheduler adapts its cadence and stays idle while inactive", () => {
  const timerApi = createTimerApi();
  let sent = 0;
  const beacons = createBeaconScheduler({ send: () => sent++, timerApi });

  assert.equal(beacons.setMode("catchup"), true);
  assert.deepEqual(timerApi.pendingIntervals(), [BEACON_INTERVALS_MS.catchup]);
  assert.equal(beacons.setMode("catchup"), false, "same cadence keeps the running interval");
  assert.equal(beacons.setMode("synced"), true);
  assert.deepEqual(timerApi.pendingIntervals(), [BEACON_INTERVALS_MS.synced]);
  timerApi.tickIntervals();
  assert.equal(sent, 1);

  assert.equal(beacons.setMode("unknown", { active: false }), false);
  assert.deepEqual(timerApi.pendingIntervals(), []);
  assert.equal(beacons.active, false);

  beacons.setMode("normal");
  beacons.destroy();
  assert.deepEqual(timerApi.pendingIntervals(), []);
  assert.equal(beacons.currentMs, null);
});

test("reactions render into their container and copy feedback restores labels", async () => {
  const timerApi = createTimerApi();
  const container = {
    children: [],
    appendChild(child) {
      this.children.push(child);
    },
  };
  const body = {
    children: [],
    appendChild(child) {
      this.children.push(child);
    },
  };
  const elements = { "wp-reactions-container": container };
  const documentRef = {
    body,
    getElementById: (id) => elements[id] ?? null,
    createElement: (tag) => ({
      tag,
      style: {},
      attributes: {},
      setAttribute(name, value) {
        this.attributes[name] = value;
      },
      select() {},
      remove() {
        this.removed = true;
      },
    }),
    execCommand: () => true,
  };
  const written = [];
  const presenter = createReactionPresenter({
    documentRef,
    navigatorRef: { clipboard: { writeText: async (text) => written.push(text) } },
    random: () => 0.5,
    timerApi,
  });

  assert.equal(presenter.showFloatingReaction({ emoji: "🔥" }), true);
  assert.equal(container.children[0].textContent, "🔥");
  assert.equal(container.children[0].style.left, "40px");
  assert.equal(presenter.showFloatingReaction({ emoji: 42 }), false);
  timerApi.fireTimeout(2_000);
  assert.equal(container.children[0].removed, true);

  const labels = [];
  const button = {
    getAttribute: () => "Copiar convite",
    setAttribute: (_name, value) => labels.push(value),
  };
  assert.equal(
    await presenter.copyInvite({
      detail: { text: "https://x/party" },
      target: { closest: () => button },
    }),
    true,
  );
  assert.deepEqual(written, ["https://x/party"]);
  assert.equal(body.children[0].id, "watch-party-copy-status");
  assert.equal(body.children[0].textContent, "Link da Watch Party copiado.");
  assert.deepEqual(labels, ["Link copiado"]);
  timerApi.fireTimeout(2_000);
  assert.deepEqual(labels, ["Link copiado", "Copiar convite"]);

  const fallback = createReactionPresenter({ documentRef, navigatorRef: {}, timerApi });
  assert.equal(
    await fallback.copyInvite({ detail: { text: "abc" } }),
    true,
    "execCommand fallback",
  );
  assert.equal(await fallback.copyInvite({ detail: { text: "" } }), false);
  fallback.destroy();
});
