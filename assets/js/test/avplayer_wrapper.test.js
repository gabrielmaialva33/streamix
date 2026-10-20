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

const stream = (id, mediaType, metadata = {}, extra = {}) => ({
  id,
  index: id,
  mediaType,
  metadata,
  timeBase: { num: 1, den: 1_000 },
  ...extra,
});

// The GIndex MKV that listed a dozen "audio" tracks: two real audio streams and
// subtitles whose low BPS fooled the old bitrate guess.
const mkvStreams = () => [
  stream(0, "Video", { BPS: "8000000" }),
  stream(1, "Audio", { language: "por", BPS: "256000" }, { codecparProxy: { channels: 2 } }),
  stream(
    2,
    "Audio",
    { language: "eng", BPS: "640000" },
    {
      codecparProxy: { chLayout: { nbChannels: 6 } },
    },
  ),
  stream(3, "Subtitle", { language: "por", BPS: "120" }),
  stream(4, "Subtitle", { language: "eng", title: "SDH", BPS: "130" }, { disposition: 0x40 }),
];

test("lists audio tracks by media type, with language, channels and selection", async () => {
  const wrapper = createWrapper();
  wrapper.player = createPlayer({ getStreams: mkvStreams, getSelectedAudioStreamId: () => 2 });

  assert.deepEqual(await wrapper.getAudioTracks(), [
    {
      id: 1,
      index: 0,
      streamIndex: 1,
      label: "Audio 1",
      language: "por",
      channels: 2,
      selected: false,
    },
    {
      id: 2,
      index: 1,
      streamIndex: 2,
      label: "Audio 2",
      language: "eng",
      channels: 6,
      selected: true,
    },
  ]);

  const subtitles = await wrapper.getSubtitleTracks();
  assert.deepEqual(
    subtitles.map(({ id, label, language, forced }) => ({ id, label, language, forced })),
    [
      { id: 3, label: "Subtitle 1", language: "por", forced: false },
      { id: 4, label: "SDH", language: "eng", forced: true },
    ],
  );
});

const withWindow = async (fn) => {
  const previous = globalThis.window;
  globalThis.window = {};
  try {
    await fn();
  } finally {
    globalThis.window = previous;
  }
};

test("play starts the subtitle renderer and hides it until the viewer picks a track", () =>
  withWindow(async () => {
    const calls = [];
    const wrapper = createWrapper();
    wrapper.player = createPlayer({
      getStreams: mkvStreams,
      async play(options) {
        calls.push(["play", options]);
      },
      async selectSubtitle(id) {
        calls.push(["subtitle", id]);
      },
      setSubtitleEnable(enabled) {
        calls.push(["subtitle-enabled", enabled]);
      },
    });

    await wrapper.play();
    await wrapper.selectSubtitleTrack(4);
    // A later play (resume) must not hide the track the viewer chose.
    await wrapper.play();

    assert.deepEqual(calls, [
      ["play", { video: true, audio: true, subtitle: true }],
      ["subtitle-enabled", false],
      ["subtitle", 4],
      ["subtitle-enabled", true],
      ["play", { video: true, audio: true, subtitle: true }],
    ]);
  }));

test("play keeps the subtitle renderer off when a stream would crash it", () =>
  withWindow(async () => {
    const calls = [];
    const wrapper = createWrapper();
    const broken = stream(5, "Subtitle", { language: "spa" }, { timeBase: { num: 0, den: 1_000 } });
    wrapper.player = createPlayer({
      getStreams: () => [...mkvStreams(), broken],
      async play(options) {
        calls.push(["play", options]);
      },
      setSubtitleEnable(enabled) {
        calls.push(["subtitle-enabled", enabled]);
      },
    });

    await wrapper.play();

    assert.deepEqual(calls, [["play", { video: true, audio: true, subtitle: false }]]);
  }));

test("Matroska tracks without a language are English, and libmedia's default subtitle is not the viewer's", async () => {
  const wrapper = createWrapper();
  wrapper.currentUrl = "https://example.test/stream/episode.mkv";
  wrapper.player = createPlayer({
    getStreams: () => [
      stream(1, "Audio", {}),
      stream(3, "Subtitle", {}),
      stream(4, "Subtitle", { language: "por" }),
    ],
    getSelectedSubtitleStreamId: () => 4,
    async selectSubtitle() {},
    setSubtitleEnable() {},
  });

  const [audioTrack] = await wrapper.getAudioTracks();
  assert.equal(audioTrack.language, "eng");

  const hidden = await wrapper.getSubtitleTracks();
  assert.deepEqual(
    hidden.map(({ language, selected }) => ({ language, selected })),
    [
      { language: "eng", selected: false },
      { language: "por", selected: false },
    ],
  );

  await wrapper.selectSubtitleTrack(4);
  const chosen = await wrapper.getSubtitleTracks();
  assert.deepEqual(
    chosen.map(({ selected }) => selected),
    [false, true],
  );

  // Other containers keep an empty language.
  wrapper.currentUrl = "https://example.test/stream/movie.mp4";
  assert.equal((await wrapper.getAudioTracks())[0].language, "");
});

test("picking the subtitle libmedia already holds only enables it", async () => {
  const calls = [];
  const wrapper = createWrapper();
  wrapper.player = createPlayer({
    getSelectedSubtitleStreamId: () => 3,
    async selectSubtitle(id) {
      calls.push(["subtitle", id]);
    },
    setSubtitleEnable(enabled) {
      calls.push(["subtitle-enabled", enabled]);
    },
  });

  await wrapper.selectSubtitleTrack(3);
  await wrapper.selectSubtitleTrack(4);

  assert.deepEqual(calls, [
    ["subtitle-enabled", true],
    ["subtitle", 4],
    ["subtitle-enabled", true],
  ]);
});
