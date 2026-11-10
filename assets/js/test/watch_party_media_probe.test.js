import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

import { ENGINE_SELECTION } from "../player/engine_contract.js";
import { selectEngine } from "../player/engine_selector.js";
import { LifecycleScope } from "../player/lifecycle_scope.js";
import { probeMediaCapability } from "../player/media_capability_policy.js";
import {
  createMediaEventBindings,
  MEDIA_EVENT_BINDINGS_HOST_METHODS,
} from "../player/media_event_bindings.js";
import { NativeBufferingController } from "../player/native_buffering_controller.js";
import { createNativePlaybackEngine } from "../player/native_playback_engine.js";
import { emitPlaybackEvent, installPlaybackBridge } from "../player/playback_bridge.js";
import { createWatchPartyPlayerBinding } from "../watch_party/player_binding.js";
import {
  createPlaybackCommandHarness,
  settleCommands,
} from "./support/playback_command_harness.js";

// Execute the exact browser fixture passed to add_init_script, without rewriting
// its code or substituting the production capability probe / engine selector.
const e2eSource = readFileSync(
  new URL("../../../test/streamix_web/e2e/watch_party_sync_test.exs", import.meta.url),
  "utf8",
);
const probeSource = e2eSource
  .split("  defp install_media_probe(session) do")[1]
  .match(/source = """\n([\s\S]*?)\n {4}"""/)[1];

for (const [name, profile] of [
  ["unsupported", { supported: false, smooth: false, powerEfficient: false }],
  ["not smooth", { supported: true, smooth: false, powerEfficient: false }],
  ["supported", { supported: true, smooth: true, powerEfficient: true }],
  ["unavailable", null],
]) {
  test(`watch party media fixture selects native when host decoding is ${name}`, async () => {
    class MediaElement extends EventTarget {}
    const navigator = profile ? { mediaCapabilities: { decodingInfo: async () => profile } } : {};
    vm.runInNewContext(probeSource, {
      navigator,
      window: {},
      document: new EventTarget(),
      HTMLMediaElement: MediaElement,
      Event,
      queueMicrotask,
    });

    const video = new MediaElement();
    assert.equal(video.canPlayType("video/mp4"), "probably");
    const mediaCapability = await probeMediaCapability({
      decodingInfo: navigator.mediaCapabilities?.decodingInfo,
    });
    assert.equal(
      selectEngine({ streamType: "mp4", sourceType: "xtream", mediaCapability }),
      ENGINE_SELECTION.NATIVE,
      "the HTMLMediaElement fixture must not start the real AVPlayer/WASM pipeline",
    );
    await assertHostPauseAfterSeek(video);
  });
}

async function assertHostPauseAfterSeek(video) {
  const root = new EventTarget();
  root.querySelector = (selector) => (selector === "video" ? video : null);
  const ui = { hideLoading() {}, hideError() {}, updatePlayPauseUI() {} };
  const buffering = new NativeBufferingController({
    contentType: "vod",
    video,
    playerUI: ui,
    emit() {},
  });
  const engine = createNativePlaybackEngine({
    video,
    beforeSeek: () => buffering.prepareSeek(),
    resetSourceOnDestroy: false,
  });
  const { controller } = createPlaybackCommandHarness({
    state: { contentType: "vod", video, nativeEngine: engine, managedEngine: engine },
    boundaries: { getRoot: () => root, emitPlaybackEvent },
  });
  const disposeBridge = installPlaybackBridge(root, controller);
  const lifecycle = new LifecycleScope();
  const host = Object.fromEntries(
    MEDIA_EVENT_BINDINGS_HOST_METHODS.map((name) => [name, () => {}]),
  );
  Object.assign(host, {
    getBufferingController: () => buffering,
    getUiController: () => ui,
    getIosPwaController: () => ({ persist() {}, pauseWasUserInitiated: () => true }),
    getWatchPartyPolicy: () => ({ shouldReapplyHoldOnPlay: () => false }),
    usesNativePlaybackEvents: () => true,
    isVodContent: () => true,
    emitPlaybackEvent: (type) => emitPlaybackEvent(root, type),
  });
  createMediaEventBindings({ host, lifecycle, root, video }).bindMediaEvents();
  const forwarded = [];
  const binding = createWatchPartyPlayerBinding({
    documentRef: { getElementById: () => root },
    isHost: true,
    onBuffering() {},
    onHostPlaybackEvent: (event, position) => forwarded.push([event, position]),
  });
  binding.ensure();
  try {
    await root.streamixPlayback.play();
    await root.streamixPlayback.pause();
    root.streamixPlayback.seekTo(33);
    await settleCommands();
    await root.streamixPlayback.play();
    assert.equal(video.paused, false);
    assert.deepEqual(forwarded.at(-1), ["wp_play", 33]);
    await root.streamixPlayback.pause();
    assert.equal(video.paused, true);
    assert.deepEqual(forwarded.at(-1), ["wp_pause", 33]);
  } finally {
    binding.destroy();
    lifecycle.dispose();
    disposeBridge();
    buffering.destroy();
    controller.destroy();
    engine.destroy();
  }
}
