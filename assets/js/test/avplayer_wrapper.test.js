import assert from "node:assert/strict";
import test from "node:test";

import { AVPlayerWrapper, isAVPlayerDestroyedError } from "../media/avplayer_wrapper.js";

const deferred = () => {
  let resolve;
  const promise = new Promise((done) => {
    resolve = done;
  });
  return { promise, resolve };
};

const createRuntime = () => ({
  AVPlayer: { audioContext: { state: "closed" } },
  _avplayerInstanceCount: 0,
});

const createPlayer = (overrides = {}) => ({
  destroy() {},
  load() {},
  on() {},
  stop() {},
  ...overrides,
});

const createWrapper = (options = {}) =>
  new AVPlayerWrapper({
    configureRuntime: () => {},
    createPlayer: () => createPlayer(),
    getAccelerationConfig: () => ({ enableHardware: false, enableWebCodecs: false }),
    getScriptUrls: () => ({ player: "player", polyfill: "polyfill" }),
    loadScript: async () => {},
    navigatorRef: { hardwareConcurrency: 8, userAgent: "test" },
    windowRef: createRuntime(),
    ...options,
  });

test("concurrent init calls share one initialization promise", async () => {
  const firstScript = deferred();
  let scriptLoads = 0;
  let playersCreated = 0;
  const wrapper = createWrapper({
    createPlayer: () => {
      playersCreated += 1;
      return createPlayer();
    },
    loadScript: async () => {
      scriptLoads += 1;
      if (scriptLoads === 1) await firstScript.promise;
    },
  });

  const first = wrapper.init();
  const second = wrapper.init();
  assert.equal(first, second);

  firstScript.resolve();
  await first;

  assert.equal(scriptLoads, 2);
  assert.equal(playersCreated, 1);
  assert.ok(wrapper.player);
  await wrapper.destroy();
});

test("destroy during a script await cannot resurrect AVPlayer", async () => {
  const script = deferred();
  let playersCreated = 0;
  let readyCalls = 0;
  let errorCalls = 0;
  const wrapper = createWrapper({
    createPlayer: () => {
      playersCreated += 1;
      return createPlayer();
    },
    loadScript: () => script.promise,
    onError: () => {
      errorCalls += 1;
    },
    onReady: () => {
      readyCalls += 1;
    },
  });

  const initialization = wrapper.init();
  await wrapper.destroy();
  script.resolve();
  await initialization;

  assert.equal(playersCreated, 0);
  assert.equal(readyCalls, 0);
  assert.equal(errorCalls, 0);
  assert.equal(wrapper.player, null);
  assert.equal(wrapper.isReady, false);
});

test("destroy during load rejects as cancellation without duplicate error callback", async () => {
  const loadGate = deferred();
  let errorCalls = 0;
  const player = createPlayer({ load: () => loadGate.promise });
  const wrapper = createWrapper({
    createPlayer: () => player,
    onError: () => {
      errorCalls += 1;
    },
  });
  await wrapper.init();

  const loading = wrapper.load("https://example.test/video.mp4");
  await Promise.resolve();
  await wrapper.destroy();
  loadGate.resolve();

  await assert.rejects(loading, isAVPlayerDestroyedError);
  assert.equal(errorCalls, 0);
  assert.equal(wrapper.player, null);
});

test("exposes stable AVPlayer track capability results", async () => {
  const calls = [];
  const wrapper = createWrapper();
  wrapper.player = createPlayer({
    async selectAudio(id) {
      calls.push(["audio", id]);
    },
    async selectSubtitle(id) {
      calls.push(["subtitle", id]);
    },
    setSubtitleEnable(enabled) {
      calls.push(["subtitle-enabled", enabled]);
    },
    setSubtitleDelay(delay) {
      calls.push(["subtitle-delay", delay]);
    },
    async loadExternalSubtitle(options) {
      calls.push(["external-subtitle", options]);
      return 91;
    },
  });
  wrapper.getCurrentTime = () => 0;

  assert.equal(await wrapper.selectAudioTrack(17), 17);
  assert.equal(await wrapper.selectSubtitleTrack(23), 23);
  assert.equal(await wrapper.selectSubtitleTrack(-1), -1);
  assert.equal(wrapper.setSubtitleDelay(125.9), 125);
  assert.equal(wrapper.setSubtitleDelay(Number.NaN), false);
  assert.equal(await wrapper.loadExternalSubtitle({ source: "blob:subtitle", lang: "pt-BR" }), 91);

  assert.deepEqual(calls, [
    ["audio", 17],
    ["subtitle", 23],
    ["subtitle-enabled", true],
    ["subtitle-enabled", false],
    ["subtitle-delay", 125],
    ["external-subtitle", { source: "blob:subtitle", lang: "pt-BR" }],
  ]);
});

test("track selection and delay degrade safely before AVPlayer is ready", async () => {
  const wrapper = createWrapper();

  assert.equal(await wrapper.selectAudioTrack(1), false);
  assert.equal(await wrapper.selectSubtitleTrack(1), false);
  assert.equal(wrapper.setSubtitleDelay(100), false);
});
