import assert from "node:assert/strict";
import test from "node:test";

import {
  configureNativePlaybackElement,
  nativePreloadMode,
  waitForNativeReady,
  waitForNativeSeek,
} from "../player/native_playback_controller.js";

class FakeVideo extends EventTarget {
  constructor() {
    super();
    this.autoplay = true;
    this.preload = "";
    this.readyState = 0;
    this.currentTime = 0;
    this.removedAttributes = [];
  }

  removeAttribute(name) {
    this.removedAttributes.push(name);
  }
}

function fakeTimers() {
  const cleared = [];
  let scheduled = null;

  return {
    api: {
      setTimeout(callback, timeout) {
        scheduled = { callback, timeout };
        return 41;
      },
      clearTimeout(id) {
        cleared.push(id);
      },
    },
    get scheduled() {
      return scheduled;
    },
    cleared,
  };
}

test("configures native playback without autoplay before a source is attached", () => {
  const video = new FakeVideo();

  configureNativePlaybackElement(video);

  assert.equal(video.autoplay, false);
  assert.equal(video.preload, "none");
  assert.deepEqual(video.removedAttributes, ["autoplay"]);
});

test("preloads metadata only when playback must resume before play", () => {
  const video = new FakeVideo();

  configureNativePlaybackElement(video, { resumeTime: 84 });

  assert.equal(nativePreloadMode(0), "none");
  assert.equal(nativePreloadMode(84), "metadata");
  assert.equal(video.preload, "metadata");
});

test("metadata readiness resolves on the first media signal and clears its timeout", async () => {
  const video = new FakeVideo();
  const timers = fakeTimers();
  const ready = waitForNativeReady({
    video,
    isCurrent: () => true,
    timerApi: timers.api,
  });

  assert.deepEqual(timers.scheduled, {
    callback: timers.scheduled.callback,
    timeout: 2_500,
  });

  video.dispatchEvent(new Event("loadedmetadata"));
  await ready;
  video.dispatchEvent(new Event("canplay"));

  assert.deepEqual(timers.cleared, [41]);
});

test("a stale playback session does not wait for media events", async () => {
  const video = new FakeVideo();
  const timers = fakeTimers();

  await waitForNativeReady({
    video,
    isCurrent: () => false,
    timerApi: timers.api,
  });

  assert.deepEqual(timers.cleared, []);
  assert.equal(timers.scheduled, null);
});

test("seek waits for completion only while the playback session is current", async () => {
  const video = new FakeVideo();
  const timers = fakeTimers();
  const seeked = waitForNativeSeek({
    video,
    targetTime: 84,
    isCurrent: () => true,
    timerApi: timers.api,
  });

  assert.equal(video.currentTime, 84);
  video.dispatchEvent(new Event("seeked"));
  await seeked;

  assert.deepEqual(timers.cleared, [41]);

  video.currentTime = 12;
  await waitForNativeSeek({
    video,
    targetTime: 96,
    isCurrent: () => false,
    timerApi: timers.api,
  });
  assert.equal(video.currentTime, 12);
});

test("a rejected native seek resolves locally without emitting a media error", async () => {
  class RejectingVideo extends EventTarget {
    set currentTime(_value) {
      throw new Error("seek rejected");
    }
  }

  const video = new RejectingVideo();
  const reported = [];
  let mediaErrors = 0;
  video.addEventListener("error", () => {
    mediaErrors += 1;
  });

  await waitForNativeSeek({
    video,
    targetTime: 30,
    isCurrent: () => true,
    onSeekError: (error) => reported.push(error.message),
  });

  assert.deepEqual(reported, ["seek rejected"]);
  assert.equal(mediaErrors, 0);
});
