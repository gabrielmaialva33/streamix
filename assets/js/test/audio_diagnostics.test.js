import assert from "node:assert/strict";
import { getEventListeners } from "node:events";
import test from "node:test";
import { detectAudioIssue } from "../media/audio_diagnostics.js";
import { clock } from "./support/playback_clock.js";

function harness(t, { playing = true, level = 10, capture = true } = {}) {
  const timerApi = clock();
  t.mock.method(globalThis, "setTimeout", timerApi.setTimeout);
  t.mock.method(globalThis, "clearTimeout", timerApi.clearTimeout);
  const contexts = [];
  let reroutes = 0,
    stopped = 0;
  const node = () => ({ connect() {}, disconnect() {} });
  class AudioContext {
    constructor() {
      this.state = "running";
      this.destination = {};
      contexts.push(this);
    }
    createMediaElementSource() {
      reroutes++;
      return node();
    }
    createMediaStreamSource() {
      return node();
    }
    createAnalyser() {
      return { ...node(), frequencyBinCount: 8, getByteFrequencyData: (a) => a.fill(level) };
    }
    close() {
      this.state = "closed";
      return Promise.resolve();
    }
  }
  const old = Object.getOwnPropertyDescriptor(globalThis, "window");
  Object.defineProperty(globalThis, "window", { configurable: true, value: { AudioContext } });
  t.after(() =>
    old ? Object.defineProperty(globalThis, "window", old) : delete globalThis.window,
  );
  const video = Object.assign(new EventTarget(), {
    readyState: playing ? 3 : 0,
    paused: !playing,
    currentTime: 1,
  });
  if (capture)
    video.captureStream = () => ({
      getAudioTracks: () => [{}],
      getTracks: () => [{ stop: () => stopped++ }],
    });
  const options = { timerApi, AudioContextClass: AudioContext };
  return { timerApi, video, contexts, options, reroutes: () => reroutes, stopped: () => stopped };
}

test("healthy audio is measured without rerouting the element; owned capture closes cleanly", async (t) => {
  const h = harness(t);
  const result = detectAudioIssue(h.video, h.options);
  h.timerApi.advance(200);
  assert.equal(await result, false);
  assert.equal(h.reroutes(), 0, "probe must never own the element output route");
  assert.equal(h.contexts[0].state, "closed");
  assert.equal(h.stopped(), 1);
});

test("timeout while awaiting playing removes listener and owns no surviving context", async (t) => {
  const h = harness(t, { playing: false });
  const result = detectAudioIssue(h.video, h.options);
  h.timerApi.advance(5000);
  assert.equal(await result, false);
  assert.equal(getEventListeners(h.video, "playing").length, 0);
  assert.ok(h.contexts.every((c) => c.state === "closed"));
  h.video.dispatchEvent(new Event("playing"));
  h.timerApi.advance(10000);
  assert.ok(h.contexts.every((c) => c.state === "closed"));
});

test("abort settles detection immediately and a second detection cancels the first", async (t) => {
  const h = harness(t, { level: 0 });
  const controller = new AbortController();
  const first = detectAudioIssue(h.video, { ...h.options, signal: controller.signal });
  controller.abort();
  assert.equal(await first, false);
  assert.ok(h.contexts.every((c) => c.state === "closed"));
  const second = detectAudioIssue(h.video, h.options);
  const third = detectAudioIssue(h.video, h.options);
  h.timerApi.advance(5000);
  assert.equal(await second, false);
  assert.equal(await third, true);
  assert.equal(getEventListeners(h.video, "playing").length, 0);
});

test("unsupported non-invasive capture is inconclusive and never creates an element source", async (t) => {
  const h = harness(t, { capture: false });
  const result = detectAudioIssue(h.video, h.options);
  h.timerApi.advance(5000);
  assert.equal(await result, false);
  assert.equal(h.reroutes(), 0);
  assert.equal(h.contexts.length, 0);
});

for (const method of ["webkitAudioDecodedByteCount", "audioTracks"]) {
  test(`abort cancels ${method} metadata/playing waits`, async (t) => {
    const h = harness(t, { playing: false });
    h.video[method] = method === "audioTracks" ? [] : 0;
    const controller = new AbortController();
    const result = detectAudioIssue(h.video, { ...h.options, signal: controller.signal });
    controller.abort();
    h.timerApi.advance(5000);
    assert.equal(await result, false);
    assert.equal(getEventListeners(h.video, "playing").length, 0);
    assert.equal(getEventListeners(h.video, "loadedmetadata").length, 0);
  });
}
