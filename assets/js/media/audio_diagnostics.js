import { avplayerLogger as log } from "../core/logger.js";

// One advisory probe at a time; native activation owns cancellation via AbortSignal.
let activeAudioDetection = null;

/** Returns true only for observed missing audio; abort/timeout/unsupported are inconclusive. */
export function detectAudioIssue(
  videoElement,
  {
    signal,
    timerApi = globalThis,
    AudioContextClass = globalThis.window?.AudioContext || globalThis.window?.webkitAudioContext,
  } = {},
) {
  activeAudioDetection?.cancel();

  return new Promise((resolve) => {
    let settled = false;
    let audioContext = null;
    let stream = null;
    let source = null;
    let analyser = null;
    const timers = new Set();
    const listeners = [];
    const detection = { cancel: () => finish(false) };
    activeAudioDetection = detection;

    const dispose = (operation) => {
      try {
        Promise.resolve(operation()).catch(() => {});
      } catch {
        // Cleanup must settle the probe even when a browser resource is already gone.
      }
    };
    function finish(issue) {
      if (settled) return;
      settled = true;
      for (const timer of timers) timerApi.clearTimeout(timer);
      timers.clear();
      for (const [event, handler] of listeners) videoElement.removeEventListener(event, handler);
      signal?.removeEventListener("abort", detection.cancel);
      dispose(() => source?.disconnect());
      dispose(() => analyser?.disconnect());
      dispose(() => {
        for (const track of stream?.getTracks() ?? []) dispose(() => track.stop());
      });
      // This context only analyzes captured tracks; it never owns the video's speaker route.
      dispose(() => audioContext?.close());
      if (activeAudioDetection === detection) activeAudioDetection = null;
      resolve(issue);
    }
    const schedule = (callback, delay) => {
      if (settled) return;
      const timer = timerApi.setTimeout(() => {
        timers.delete(timer);
        if (settled) return;
        try {
          callback();
        } catch (error) {
          log.debug("Audio probe unavailable:", error);
          finish(false);
        }
      }, delay);
      timers.add(timer);
    };
    const once = (event, callback) => {
      const handler = () => {
        videoElement.removeEventListener(event, handler);
        if (!settled) schedule(callback, 0);
      };
      listeners.push([event, handler]);
      videoElement.addEventListener(event, handler);
    };
    signal?.addEventListener("abort", detection.cancel, { once: true });
    if (signal?.aborted) return finish(false);
    schedule(() => finish(false), 5000);

    if ("webkitAudioDecodedByteCount" in videoElement) {
      const check = () => {
        if (videoElement.currentTime > 0.5) finish(videoElement.webkitAudioDecodedByteCount === 0);
        else if (!videoElement.paused) schedule(check, 100);
      };
      if (videoElement.readyState >= 3 && !videoElement.paused) schedule(check, 300);
      else once("playing", () => schedule(check, 300));
      return;
    }
    if (videoElement.audioTracks) {
      const check = () => finish(videoElement.audioTracks.length === 0);
      if (videoElement.readyState >= 1) check();
      else once("loadedmetadata", check);
      return;
    }

    // createMediaElementSource permanently reroutes the element (even after disconnect/close).
    // Analyze an independent capture instead, with no connection to the audio destination.
    const capture = videoElement.captureStream || videoElement.mozCaptureStream;
    if (!capture || !AudioContextClass) return finish(false);
    const start = () => {
      stream = capture.call(videoElement);
      if (!stream.getAudioTracks().length) return finish(false);
      audioContext = new AudioContextClass();
      source = audioContext.createMediaStreamSource(stream);
      analyser = audioContext.createAnalyser();
      analyser.fftSize = 256;
      source.connect(analyser);
      const data = new Uint8Array(analyser.frequencyBinCount);
      let checks = 0;
      const check = () => {
        if (audioContext.state !== "running" || videoElement.paused) return finish(false);
        analyser.getByteFrequencyData(data);
        if (data.reduce((sum, value) => sum + value, 0) / data.length > 5) return finish(false);
        if (++checks >= 10) return finish(true);
        schedule(check, 100);
      };
      if (audioContext.state === "suspended") {
        Promise.resolve(audioContext.resume()).then(
          () => schedule(check, 200),
          () => finish(false),
        );
      } else schedule(check, 200);
    };
    if (videoElement.readyState >= 3 && !videoElement.paused) {
      try {
        start();
      } catch (error) {
        log.debug("Audio capture unavailable:", error);
        finish(false);
      }
    } else once("playing", start);
  });
}
