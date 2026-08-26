import assert from "node:assert/strict";
import test from "node:test";

import {
  createNativeSubtitleController,
  NativeSubtitleController,
} from "../player/native_subtitle_controller.js";

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });

  return { promise, reject, resolve };
}

function createTrackElement() {
  return {
    kind: "",
    label: "",
    parentNode: null,
    src: "",
    srclang: "",
    track: {
      label: "",
      language: "",
      mode: "disabled",
    },
    remove() {
      this.parentNode?.removeChild(this);
    },
  };
}

function createVideo(existingTracks = []) {
  const children = [];
  const textTracks = [...existingTracks];

  return {
    children,
    textTracks,
    appendChild(element) {
      element.parentNode = this;
      element.track.label = element.label;
      element.track.language = element.srclang;
      children.push(element);
      textTracks.push(element.track);
      return element;
    },
    removeChild(element) {
      const childIndex = children.indexOf(element);
      if (childIndex >= 0) children.splice(childIndex, 1);

      const trackIndex = textTracks.indexOf(element.track);
      if (trackIndex >= 0) textTracks.splice(trackIndex, 1);
      element.parentNode = null;
      return element;
    },
  };
}

function createLease(source, releases) {
  return {
    source,
    release() {
      releases.push(source);
    },
  };
}

function createScheduler() {
  let nextId = 0;
  const tasks = new Map();

  return {
    cancel(id) {
      tasks.delete(id);
    },
    get size() {
      return tasks.size;
    },
    async runNext() {
      const entry = tasks.entries().next().value;
      if (!entry) return undefined;

      const [id, task] = entry;
      tasks.delete(id);
      return await task.callback();
    },
    schedule(callback, delay) {
      const id = ++nextId;
      tasks.set(id, { callback, delay });
      return id;
    },
    snapshot() {
      return [...tasks.values()].map(({ delay }) => delay);
    },
  };
}

test("validates the native subtitle lifecycle boundaries", () => {
  const video = createVideo();

  assert.throws(() => new NativeSubtitleController(), /requires a video element/);
  assert.throws(() => new NativeSubtitleController({ video }), /requires resolveSource\(\)/);
  assert.throws(
    () =>
      new NativeSubtitleController({
        video,
        resolveSource() {},
        createTrackElement: true,
      }),
    /requires createTrackElement\(\)/,
  );
});

test("owns native track creation, selection, and immutable snapshots", async () => {
  const video = createVideo();
  const releases = [];
  let resolveCalls = 0;
  const controller = createNativeSubtitleController({
    video,
    createTrackElement,
    resolveSource({ force, language, offsetMs, sessionId }) {
      resolveCalls += 1;
      assert.deepEqual(
        { force, language, offsetMs, sessionId },
        {
          force: false,
          language: "pt-BR",
          offsetMs: 250,
          sessionId: 7,
        },
      );
      return createLease("blob:subtitle-1", releases);
    },
  });

  const snapshot = await controller.load({ sessionId: 7, offsetMs: 250 });

  assert.equal(Object.isFrozen(snapshot), true);
  assert.equal(Object.isFrozen(snapshot.tracks), true);
  assert.equal(Object.isFrozen(snapshot.tracks[0]), true);
  assert.equal(snapshot.active, true);
  assert.equal(snapshot.selectedTrack, -1);
  assert.deepEqual(snapshot.tracks[0], {
    active: false,
    id: 0,
    index: 0,
    label: "Português (auto)",
    language: "pt-BR",
    selected: false,
    selectionId: 0,
  });
  assert.equal(video.children.length, 1);
  assert.equal(video.children[0].kind, "subtitles");
  assert.equal(video.children[0].src, "blob:subtitle-1");

  assert.equal(controller.select(0), 0);
  assert.equal(video.children[0].track.mode, "showing");
  assert.equal(controller.snapshot().tracks[0].selected, true);
  assert.equal(controller.select(-1), -1);
  assert.equal(video.children[0].track.mode, "disabled");
  assert.equal(controller.select(1), false);
  assert.equal(controller.select(""), false);

  assert.equal(await controller.load({ sessionId: 7 }), false);
  assert.equal(resolveCalls, 1);
  assert.deepEqual(releases, []);
});

test("does not duplicate a language already exposed by the native media element", async () => {
  const video = createVideo([
    {
      label: "Português",
      language: "por",
      mode: "hidden",
    },
  ]);
  let resolveCalls = 0;
  const controller = createNativeSubtitleController({
    video,
    createTrackElement,
    resolveSource() {
      resolveCalls += 1;
      return "blob:unexpected";
    },
  });

  assert.equal(await controller.load({ sessionId: 1, language: "pt-BR" }), false);
  assert.equal(resolveCalls, 0);
  assert.equal(video.children.length, 0);
});

test("reload replaces the track and transfers source cleanup exactly once", async () => {
  const video = createVideo();
  const releases = [];
  const sources = ["blob:first", "blob:second", "blob:third"];
  const controller = createNativeSubtitleController({
    video,
    createTrackElement,
    resolveSource() {
      return createLease(sources.shift(), releases);
    },
  });

  await controller.load({ sessionId: 2 });
  controller.select(0);
  const firstElement = video.children[0];

  const reloaded = await controller.reload({ sessionId: 2, offsetMs: 500 });
  assert.equal(reloaded.active, true);
  assert.equal(reloaded.selectedTrack, -1);
  assert.equal(firstElement.parentNode, null);
  assert.equal(video.children.length, 1);
  assert.equal(video.children[0].src, "blob:second");
  assert.deepEqual(releases, ["blob:first"]);

  assert.equal(controller.reset(), true);
  assert.equal(video.children.length, 0);
  assert.deepEqual(releases, ["blob:first", "blob:second"]);
  assert.equal(controller.reset(), false);

  await controller.load({ sessionId: 3 });
  assert.equal(controller.destroy(), true);
  assert.equal(controller.destroy(), false);
  assert.equal(video.children.length, 0);
  assert.deepEqual(releases, ["blob:first", "blob:second", "blob:third"]);
});

test("drops and releases a source resolved for a stale playback session", async () => {
  const video = createVideo();
  const pending = deferred();
  const releases = [];
  let currentSession = 11;
  const controller = createNativeSubtitleController({
    video,
    createTrackElement,
    isSessionCurrent: (sessionId) => sessionId === currentSession,
    resolveSource: () => pending.promise,
  });

  const loading = controller.load({ sessionId: 11 });
  currentSession = 12;
  pending.resolve(createLease("blob:stale", releases));

  assert.equal(await loading, false);
  assert.deepEqual(releases, ["blob:stale"]);
  assert.equal(video.children.length, 0);
  assert.equal(controller.snapshot().active, false);
});

test("reset invalidates pending source work without preventing later reuse", async () => {
  const video = createVideo();
  const first = deferred();
  const releases = [];
  let call = 0;
  const controller = createNativeSubtitleController({
    video,
    createTrackElement,
    resolveSource() {
      call += 1;
      return call === 1 ? first.promise : createLease("blob:fresh", releases);
    },
  });

  const pendingLoad = controller.load({ sessionId: 1 });
  assert.equal(controller.reset(), false);
  first.resolve(createLease("blob:cancelled", releases));
  assert.equal(await pendingLoad, false);
  assert.deepEqual(releases, ["blob:cancelled"]);

  const fresh = await controller.load({ sessionId: 2 });
  assert.equal(fresh.active, true);
  assert.equal(video.children[0].src, "blob:fresh");
});

test("debounces offset reloads and completes only the latest request", async () => {
  const video = createVideo();
  const scheduler = createScheduler();
  const releases = [];
  const calls = [];
  const completions = [];
  const controller = createNativeSubtitleController({
    video,
    cancelSchedule: (id) => scheduler.cancel(id),
    createTrackElement,
    reloadDelayMs: 150,
    resolveSource(options) {
      calls.push(options);
      return createLease(`blob:${options.offsetMs}`, releases);
    },
    schedule: (callback, delay) => scheduler.schedule(callback, delay),
  });

  await controller.load({ sessionId: 9, offsetMs: 0 });
  controller.select(0);

  assert.equal(
    controller.scheduleReload({ sessionId: 9, offsetMs: 100 }, (snapshot) =>
      completions.push(snapshot),
    ),
    true,
  );
  assert.equal(
    controller.scheduleReload({ sessionId: 9, offsetMs: 200 }, (snapshot) =>
      completions.push(snapshot),
    ),
    true,
  );
  assert.equal(scheduler.size, 1);
  assert.deepEqual(scheduler.snapshot(), [150]);

  await scheduler.runNext();

  assert.deepEqual(
    calls.map(({ force, offsetMs }) => ({ force, offsetMs })),
    [
      { force: false, offsetMs: 0 },
      { force: true, offsetMs: 200 },
    ],
  );
  assert.deepEqual(releases, ["blob:0"]);
  assert.equal(completions.length, 1);
  assert.equal(completions[0].active, true);
  assert.equal(video.children[0].src, "blob:200");
  assert.equal(controller.snapshot().reloadScheduled, false);
  assert.equal(controller.snapshot().reloading, false);
});

test("invalidates an in-flight offset reload when a newer offset is scheduled", async () => {
  const video = createVideo();
  const scheduler = createScheduler();
  const pendingReload = deferred();
  const releases = [];
  const completions = [];
  let resolveCalls = 0;
  const controller = createNativeSubtitleController({
    video,
    cancelSchedule: (id) => scheduler.cancel(id),
    createTrackElement,
    resolveSource({ offsetMs }) {
      resolveCalls += 1;
      if (resolveCalls === 1) return createLease("blob:initial", releases);
      if (resolveCalls === 2) return pendingReload.promise;
      return createLease(`blob:${offsetMs}`, releases);
    },
    schedule: (callback, delay) => scheduler.schedule(callback, delay),
  });

  await controller.load({ sessionId: 4, offsetMs: 0 });
  controller.select(0);
  controller.scheduleReload({ sessionId: 4, offsetMs: 100 }, (snapshot) =>
    completions.push([100, snapshot]),
  );

  const firstReload = scheduler.runNext();
  await Promise.resolve();
  assert.equal(resolveCalls, 2);
  assert.equal(
    controller.scheduleReload({ sessionId: 4, offsetMs: 200 }, (snapshot) =>
      completions.push([200, snapshot]),
    ),
    true,
  );

  pendingReload.resolve(createLease("blob:100", releases));
  await firstReload;

  assert.deepEqual(completions, []);
  assert.deepEqual(releases, ["blob:initial", "blob:100"]);
  assert.equal(video.children.length, 0);
  assert.equal(scheduler.size, 1);

  await scheduler.runNext();

  assert.equal(video.children.length, 1);
  assert.equal(video.children[0].src, "blob:200");
  assert.equal(completions.length, 1);
  assert.equal(completions[0][0], 200);
  assert.equal(completions[0][1].active, true);
});

test("contains resolver and cleanup failures as non-fatal diagnostics", async () => {
  const video = createVideo();
  const errors = [];
  let failResolve = true;
  const controller = createNativeSubtitleController({
    video,
    createTrackElement,
    onError: (operation, error) => errors.push([operation, error.message]),
    resolveSource() {
      if (failResolve) throw new Error("resolver failed");
      return {
        source: "blob:cleanup-error",
        release() {
          throw new Error("release failed");
        },
      };
    },
  });

  assert.equal(await controller.load({ sessionId: 1 }), false);
  failResolve = false;
  assert.equal((await controller.load({ sessionId: 1 })).active, true);
  assert.equal(controller.reset(), true);
  assert.deepEqual(errors, [
    ["load", "resolver failed"],
    ["release_source", "release failed"],
  ]);
});

test("destroy is terminal and blocks later mutations", async () => {
  const video = createVideo();
  const controller = createNativeSubtitleController({
    video,
    createTrackElement,
    resolveSource: () => "blob:subtitle",
  });

  await controller.load({ sessionId: 1 });
  assert.equal(controller.destroy(), true);
  assert.equal(await controller.load({ sessionId: 2 }), false);
  assert.equal(controller.select(0), false);
  assert.equal(controller.reload({ sessionId: 2 }), false);
  assert.equal(controller.scheduleReload({ sessionId: 2 }), false);
  assert.equal(controller.snapshot().destroyed, true);
});
