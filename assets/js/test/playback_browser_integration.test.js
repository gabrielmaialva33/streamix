import assert from "node:assert/strict";
import test from "node:test";

import { createPlaybackBrowserIntegration } from "../player/playback_browser_integration.js";

class FakeDocument extends EventTarget {
  constructor() {
    super();
    this.fullscreenElement = null;
    this.pictureInPictureElement = null;
    this.pictureInPictureEnabled = true;
  }

  async exitPictureInPicture() {
    this.pictureInPictureElement = null;
  }
}

class FakeVideo extends EventTarget {
  constructor(documentRef) {
    super();
    this.documentRef = documentRef;
    this.disablePictureInPicture = false;
    this.webkitDisplayingFullscreen = false;
    this.webkitPresentationMode = "inline";
  }

  async requestPictureInPicture() {
    this.documentRef.pictureInPictureElement = this;
  }
}

function createHarness(options = {}) {
  const calls = {
    commands: [],
    emitted: [],
    errors: [],
    fullscreen: [],
    pipAvailability: 0,
    pipDisabled: 0,
    pipStates: [],
  };
  const documentRef = options.documentRef ?? new FakeDocument();
  const video = options.video ?? new FakeVideo(documentRef);
  const state = {
    canvasPlaybackActive: false,
    contentType: "vod",
    destroyed: false,
    muted: false,
    paused: true,
    ...options.state,
  };
  const commands = {
    adjustVolume: (delta) => calls.commands.push(["adjustVolume", delta]),
    getCurrentTime: () => 42,
    getDuration: () => 120,
    getPlaybackRate: () => 1.25,
    isPaused: () => state.paused,
    seek: (seconds) => calls.commands.push(["seek", seconds]),
    seekTo: (time) => calls.commands.push(["seekTo", time]),
    setPlaybackRate: (rate) => calls.commands.push(["setPlaybackRate", rate]),
    toggleMute: () => calls.commands.push(["toggleMute"]),
    togglePlayPause: () => calls.commands.push(["togglePlayPause"]),
    ...options.commands,
  };
  const presentation = {
    disablePiP() {
      calls.pipDisabled += 1;
    },
    setPiPState(active) {
      calls.pipStates.push(Boolean(active));
      return true;
    },
    syncPiPAvailability() {
      calls.pipAvailability += 1;
      return true;
    },
    updateFullscreenUI(active) {
      calls.fullscreen.push(Boolean(active));
    },
    ...options.presentation,
  };
  const root = options.root ?? {};
  const integration = createPlaybackBrowserIntegration({
    commands,
    documentRef,
    dependencies: options.dependencies,
    emit: (event, payload) => calls.emitted.push([event, payload]),
    getCanvasPlaybackActive: () => state.canvasPlaybackActive,
    getContentType: () => state.contentType,
    getMuted: () => state.muted,
    isPlayerDestroyed: () => state.destroyed,
    metadata: { title: "Example", artist: "Streamix", album: "Streamix" },
    navigatorRef: options.navigatorRef ?? {},
    onError: (operation, error) => calls.errors.push([operation, error.message]),
    presentation,
    root,
    video,
    windowRef: options.windowRef ?? {},
  });

  return { calls, commands, documentRef, integration, presentation, root, state, video };
}

function dispatchKey(documentRef, key) {
  const event = new Event("keydown", { cancelable: true });
  Object.defineProperty(event, "key", { value: key });
  documentRef.dispatchEvent(event);
  return event;
}

test("owns keyboard commands and browser listeners with idempotent cleanup", () => {
  let keyboardOptions;
  let keyboardStarts = 0;
  let keyboardDestroys = 0;
  let contentTypeUpdates = 0;
  const harness = createHarness({
    dependencies: {
      createKeyboardManager(options) {
        keyboardOptions = options;
        return {
          destroy: () => {
            keyboardDestroys += 1;
          },
          setContentType: () => {
            contentTypeUpdates += 1;
          },
          start: () => {
            keyboardStarts += 1;
          },
        };
      },
    },
  });

  assert.equal(harness.integration.start(), true);
  assert.equal(harness.integration.start(), false);
  assert.equal(harness.integration.setupKeyboardShortcuts(), true);
  assert.equal(harness.integration.setupKeyboardShortcuts(), true);
  assert.equal(keyboardStarts, 2);
  assert.equal(contentTypeUpdates, 1);
  assert.equal(keyboardOptions.contentType, "vod");
  assert.strictEqual(keyboardOptions.documentRef, harness.documentRef);

  keyboardOptions.actions.togglePlayPause();
  keyboardOptions.actions.toggleMute();
  keyboardOptions.actions.adjustVolume(0.1);
  keyboardOptions.actions.seek(-10);
  keyboardOptions.actions.seekTo(30);
  keyboardOptions.actions.setPlaybackRate(1.5);
  assert.equal(keyboardOptions.actions.getDuration(), 120);
  assert.equal(keyboardOptions.actions.getPlaybackRate(), 1.25);
  assert.equal(keyboardOptions.actions.isPaused(), true);
  assert.equal(keyboardOptions.actions.isMuted(), false);
  assert.deepEqual(harness.calls.commands, [
    ["togglePlayPause"],
    ["toggleMute"],
    ["adjustVolume", 0.1],
    ["seek", -10],
    ["seekTo", 30],
    ["setPlaybackRate", 1.5],
  ]);

  harness.documentRef.fullscreenElement = harness.root;
  harness.documentRef.dispatchEvent(new Event("fullscreenchange"));
  harness.documentRef.fullscreenElement = null;
  harness.documentRef.dispatchEvent(new Event("webkitfullscreenchange"));
  harness.video.dispatchEvent(new Event("enterpictureinpicture"));
  harness.video.dispatchEvent(new Event("leavepictureinpicture"));
  harness.video.webkitPresentationMode = "picture-in-picture";
  harness.video.dispatchEvent(new Event("webkitpresentationmodechanged"));

  assert.deepEqual(harness.calls.fullscreen, [true, false]);
  assert.deepEqual(harness.calls.pipStates, [true, false, true]);

  harness.integration.destroy();
  harness.integration.destroy();
  harness.documentRef.dispatchEvent(new Event("fullscreenchange"));
  harness.video.dispatchEvent(new Event("enterpictureinpicture"));

  assert.equal(keyboardDestroys, 1);
  assert.deepEqual(harness.calls.fullscreen, [true, false]);
  assert.deepEqual(harness.calls.pipStates, [true, false, true]);
});

test("updates keyboard content policy without replacing or stacking its listener", () => {
  const harness = createHarness({ state: { contentType: "live" } });
  harness.integration.setupKeyboardShortcuts();

  dispatchKey(harness.documentRef, "ArrowRight");
  assert.deepEqual(harness.calls.commands, []);

  harness.state.contentType = "vod";
  harness.integration.setupKeyboardShortcuts();
  const seekEvent = dispatchKey(harness.documentRef, "ArrowRight");

  assert.equal(seekEvent.defaultPrevented, true);
  assert.deepEqual(harness.calls.commands, [["seek", 10]]);

  harness.integration.destroy();
  dispatchKey(harness.documentRef, "ArrowRight");
  assert.deepEqual(harness.calls.commands, [["seek", 10]]);
});

test("preserves standard, WebKit, and Apple touch fullscreen paths", () => {
  let standardExits = 0;
  const standard = createHarness();
  standard.documentRef.fullscreenElement = standard.root;
  standard.documentRef.exitFullscreen = () => {
    standardExits += 1;
  };
  standard.integration.toggleFullscreen();
  assert.equal(standardExits, 1);

  let webkitExits = 0;
  const webkit = createHarness();
  webkit.video.webkitDisplayingFullscreen = true;
  webkit.video.webkitExitFullscreen = () => {
    webkitExits += 1;
  };
  webkit.integration.toggleFullscreen();
  assert.equal(webkitExits, 1);

  let appleEntries = 0;
  let rootEntries = 0;
  const apple = createHarness({
    navigatorRef: { userAgent: "iPhone" },
    root: {
      requestFullscreen: () => {
        rootEntries += 1;
      },
    },
  });
  apple.video.webkitEnterFullscreen = () => {
    appleEntries += 1;
  };
  apple.integration.toggleFullscreen();
  assert.equal(appleEntries, 1);
  assert.equal(rootEntries, 0);

  const standardEntry = createHarness({
    root: {
      requestFullscreen: () => {
        rootEntries += 1;
        return Promise.resolve();
      },
    },
  });
  standardEntry.integration.toggleFullscreen();
  assert.equal(rootEntries, 1);
});

test("owns Picture-in-Picture capability, toggling, canvas disablement, and errors", async () => {
  const harness = createHarness();

  assert.equal(harness.integration.isPiPSupported(), true);
  await harness.integration.togglePiP();
  assert.strictEqual(harness.documentRef.pictureInPictureElement, harness.video);
  await harness.integration.togglePiP();
  assert.equal(harness.documentRef.pictureInPictureElement, null);
  assert.deepEqual(harness.calls.pipStates, [true, false]);

  harness.state.canvasPlaybackActive = true;
  assert.equal(harness.integration.isPiPSupported(), false);
  harness.documentRef.pictureInPictureElement = harness.video;
  harness.integration.disablePiPForCanvasPlayback();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(harness.calls.pipDisabled, 1);
  assert.equal(harness.documentRef.pictureInPictureElement, null);

  const failed = createHarness({
    dependencies: {
      isPictureInPictureSupported: () => true,
      togglePictureInPicture: async () => {
        throw new Error("denied");
      },
    },
  });
  await failed.integration.togglePiP();
  assert.deepEqual(failed.calls.errors, [["picture-in-picture", "denied"]]);
  assert.deepEqual(failed.calls.emitted, [["pip_error", { message: "denied" }]]);
});

test("composes Media Session actions, positions, and playback wake state", () => {
  const handlers = new Map();
  const positions = [];
  const wakeStates = [];
  let wakeDestroys = 0;
  const mediaSession = {
    metadata: null,
    playbackState: "none",
    setActionHandler(action, handler) {
      handlers.set(action, handler);
    },
    setPositionState(position) {
      positions.push(position);
    },
  };
  class MediaMetadata {
    constructor(metadata) {
      Object.assign(this, metadata);
    }
  }
  const harness = createHarness({
    dependencies: {
      createScreenWakeLockController: () => ({
        destroy() {
          wakeDestroys += 1;
        },
        setPlaybackActive(active) {
          wakeStates.push(active);
        },
      }),
    },
    navigatorRef: { mediaSession },
    windowRef: { MediaMetadata },
  });

  assert.equal(harness.integration.setupPlaybackSystemIntegration(), true);
  assert.equal(harness.integration.setupPlaybackSystemIntegration(), true);
  assert.equal(mediaSession.metadata.title, "Example");
  assert.deepEqual(wakeStates, [false, false]);

  handlers.get("play")();
  handlers.get("pause")();
  harness.state.paused = false;
  handlers.get("pause")();
  handlers.get("seekbackward")({ seekOffset: 5 });
  handlers.get("seekforward")({});
  handlers.get("seekto")({ seekTime: 75 });
  assert.deepEqual(harness.calls.commands, [
    ["togglePlayPause"],
    ["togglePlayPause"],
    ["seek", -5],
    ["seek", 10],
    ["seekTo", 75],
  ]);

  assert.equal(harness.integration.setPlaybackSystemState("playing"), true);
  assert.equal(mediaSession.playbackState, "playing");
  assert.deepEqual(wakeStates, [false, false, true]);
  assert.deepEqual(positions.at(-1), {
    duration: 120,
    playbackRate: 1.25,
    position: 42,
  });

  harness.state.contentType = "live";
  assert.equal(harness.integration.updateMediaSessionPosition({ force: true }), true);
  assert.equal(positions.at(-1), undefined);

  harness.state.destroyed = true;
  assert.equal(harness.integration.setPlaybackSystemState("playing"), false);
  assert.equal(harness.integration.setPlaybackSystemState("none"), true);

  harness.integration.destroy();
  harness.integration.destroy();
  assert.equal(wakeDestroys, 1);
  assert.equal(mediaSession.metadata, null);
  for (const handler of handlers.values()) assert.equal(handler, null);
});
