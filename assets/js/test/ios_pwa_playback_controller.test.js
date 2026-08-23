import assert from "node:assert/strict";
import test from "node:test";

import { createIosPwaPlaybackController } from "../player/ios_pwa_playback_controller.js";

test("persists a fresh iOS PWA VOD snapshot through injected boundaries", () => {
  let builtInput = null;
  let builtExtra = null;
  let writtenState = null;
  let savedPosition = null;

  const controller = createIosPwaPlaybackController({
    isEnabled: () => true,
    getContentType: () => "vod",
    getContentId: () => "movie-42",
    getVideo: () => ({ playbackRate: 1.25 }),
    getPath: () => "/watch/42?source=primary",
    getCurrentTime: () => 21.9,
    getDuration: () => 100.8,
    isPaused: () => false,
    getAudioState: () => ({ muted: true, volume: 0.35 }),
    buildState: (input, extra) => {
      builtInput = input;
      builtExtra = extra;
      return { ...input, ...extra };
    },
    writeState: (state) => {
      writtenState = state;
      return true;
    },
    savePlaybackPosition: (...args) => {
      savedPosition = args;
    },
  });

  assert.equal(controller.persist({ reason: "progress" }), true);
  assert.deepEqual(builtInput, {
    contentId: "movie-42",
    path: "/watch/42?source=primary",
    currentTime: 21,
    duration: 100,
    paused: false,
    muted: true,
    volume: 0.35,
    playbackRate: 1.25,
  });
  assert.deepEqual(builtExtra, { reason: "progress" });
  assert.deepEqual(savedPosition, ["movie-42", 21, 100]);
  assert.equal(writtenState.reason, "progress");
});

test("ignores persistence outside an enabled standalone VOD session", () => {
  let writes = 0;

  const controller = createIosPwaPlaybackController({
    isEnabled: () => false,
    getContentType: () => "vod",
    getContentId: () => "movie-42",
    writeState: () => {
      writes += 1;
      return true;
    },
  });

  assert.equal(controller.persist(), false);
  assert.equal(writes, 0);
});

test("classifies visibility pauses and records page lifecycle reasons", () => {
  let visibilityState = "visible";
  let paused = false;
  const reasons = [];

  const controller = createIosPwaPlaybackController({
    isEnabled: () => true,
    getContentType: () => "vod",
    getContentId: () => "movie-42",
    getVideo: () => ({ playbackRate: 1, currentTime: 10, play: () => Promise.resolve() }),
    getVisibilityState: () => visibilityState,
    getCurrentTime: () => 10,
    getDuration: () => 120,
    isPaused: () => paused,
    buildState: (input, extra) => ({ ...input, ...extra }),
    writeState: (state) => {
      reasons.push(state.reason);
      return true;
    },
    readState: () => null,
  });

  visibilityState = "hidden";
  controller.handleVisibilityChange();
  assert.equal(controller.pauseWasUserInitiated(), false);
  assert.deepEqual(reasons, ["hidden"]);

  visibilityState = "visible";
  controller.handleVisibilityChange();
  assert.equal(controller.pauseWasUserInitiated(), true);

  paused = true;
  controller.handlePageHide({ persisted: true });
  assert.deepEqual(reasons, ["hidden", "pagehide-persisted"]);
});

test("restores audio, rate, seek position, and playing intent", async () => {
  const video = {
    currentTime: 2,
    playbackRate: 1,
    pauseCalls: 0,
    playCalls: 0,
    pause() {
      this.pauseCalls += 1;
    },
    play() {
      this.playCalls += 1;
      return Promise.resolve();
    },
  };
  let audioState = { muted: false, volume: 0.8 };
  let applyCalls = 0;

  const controller = createIosPwaPlaybackController({
    isEnabled: () => true,
    getContentType: () => "vod",
    getContentId: () => "movie-42",
    getVideo: () => video,
    getAudioState: () => audioState,
    setAudioState: (nextState) => {
      audioState = nextState;
    },
    applyAudioState: () => {
      applyCalls += 1;
    },
    readState: () => ({
      contentId: "movie-42",
      time: 48,
      playbackRate: 1.5,
      volume: 0.4,
      muted: true,
      userPaused: false,
      wasPlaying: true,
    }),
  });

  await controller.resume();

  assert.deepEqual(audioState, { muted: true, volume: 0.4 });
  assert.equal(applyCalls, 1);
  assert.equal(video.playbackRate, 1.5);
  assert.equal(video.currentTime, 48);
  assert.equal(video.playCalls, 1);
  assert.equal(video.pauseCalls, 0);
});

test("keeps a user-paused snapshot paused", async () => {
  const video = {
    currentTime: 20,
    playbackRate: 1,
    pauseCalls: 0,
    playCalls: 0,
    pause() {
      this.pauseCalls += 1;
    },
    play() {
      this.playCalls += 1;
      return Promise.resolve();
    },
  };

  const controller = createIosPwaPlaybackController({
    isEnabled: () => true,
    getContentType: () => "vod",
    getContentId: () => "movie-42",
    getVideo: () => video,
    readState: () => ({
      contentId: "movie-42",
      time: 20,
      playbackRate: 1,
      volume: 1,
      muted: false,
      userPaused: true,
      wasPlaying: false,
    }),
  });

  await controller.resume();

  assert.equal(video.pauseCalls, 1);
  assert.equal(video.playCalls, 0);
});
