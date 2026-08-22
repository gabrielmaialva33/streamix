import assert from "node:assert/strict";
import test from "node:test";
import {
  createMediaSessionController,
  normalizeMediaPositionState,
} from "../player/media_session_controller.js";

class FakeMediaMetadata {
  constructor(value) {
    Object.assign(this, value);
  }
}

function createMediaSessionHarness() {
  const handlers = new Map();
  const positions = [];
  const session = {
    metadata: null,
    playbackState: "none",
    setActionHandler(action, handler) {
      handlers.set(action, handler);
    },
    setPositionState(state) {
      positions.push(state);
    },
  };

  return { handlers, positions, session };
}

test("drives metadata, actions, explicit playback state, and VOD position", () => {
  const harness = createMediaSessionHarness();
  const calls = [];
  const controller = createMediaSessionController({
    navigatorRef: { mediaSession: harness.session },
    windowRef: { MediaMetadata: FakeMediaMetadata },
    metadata: { title: "Filme", artist: "Streamix", album: "Streamix" },
    actions: {
      play: () => calls.push("play"),
      pause: () => calls.push("pause"),
      seekto: ({ seekTime }) => calls.push(["seekto", seekTime]),
    },
  });

  assert.equal(controller.setup(), true);
  assert.equal(harness.session.metadata.title, "Filme");

  harness.handlers.get("play")();
  harness.handlers.get("pause")();
  harness.handlers.get("seekto")({ seekTime: 42 });
  assert.deepEqual(calls, ["play", "pause", ["seekto", 42]]);

  assert.equal(controller.setPlaybackState("playing"), true);
  assert.equal(harness.session.playbackState, "playing");
  assert.equal(
    controller.setPositionState({ duration: 120, position: 150, playbackRate: 1.25 }),
    true,
  );
  assert.deepEqual(harness.positions.at(-1), {
    duration: 120,
    position: 120,
    playbackRate: 1.25,
  });

  controller.destroy();
  assert.equal(harness.session.playbackState, "none");
  assert.equal(harness.session.metadata, null);
  assert.equal(harness.handlers.get("play"), null);
  assert.equal(harness.positions.at(-1), undefined);
});

test("normalizes position state and ignores invalid media values", () => {
  assert.deepEqual(normalizeMediaPositionState({ duration: 100, position: -5, playbackRate: 0 }), {
    duration: 100,
    position: 0,
    playbackRate: 1,
  });
  assert.equal(normalizeMediaPositionState({ duration: 0, position: 1 }), null);
  assert.equal(normalizeMediaPositionState({ duration: 10, position: Number.NaN }), null);

  const harness = createMediaSessionHarness();
  const controller = createMediaSessionController({
    navigatorRef: { mediaSession: harness.session },
    windowRef: {},
  });

  controller.setup();
  assert.equal(controller.setPositionState({ duration: 0, position: 0 }), false);
  assert.deepEqual(harness.positions, []);
});

test("is a no-op when Media Session is unavailable", () => {
  const controller = createMediaSessionController({ navigatorRef: {}, windowRef: {} });

  assert.equal(controller.supported, false);
  assert.equal(controller.setup(), false);
  assert.equal(controller.setPlaybackState("playing"), false);
  assert.equal(controller.setPositionState({ duration: 10, position: 1 }), false);
  controller.destroy();
});
