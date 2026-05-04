/**
 * MSE-in-Workers feature detection.
 *
 * The previous version of this file shipped a `WorkerMSEBridge`, a
 * `createMSEHandler` factory, and a worker bootstrap (~480 LoC) that
 * nothing in the app ever used — hls.js v1.7+ ships its own MSE-in-
 * worker support so we never wired this up. The audit confirmed it
 * was shelfware. Trimmed to just the capability probes referenced
 * by `video_player.js` startup diagnostics.
 */

/**
 * Check if MSE in Workers is supported. Detected via
 * `MediaSource.canConstructInDedicatedWorker` (Chrome 108+, Firefox 130+).
 */
export function isMSEInWorkersSupported() {
  return (
    typeof MediaSource !== "undefined" &&
    MediaSource.canConstructInDedicatedWorker === true &&
    typeof Worker !== "undefined"
  );
}

/**
 * Check if transferable streams are supported (used in `getMSEWorkerCapabilityReport`).
 */
export function isTransferableStreamsSupported() {
  try {
    const stream = new ReadableStream();
    return typeof stream.tee === "function" && typeof MessageChannel !== "undefined";
  } catch {
    return false;
  }
}

/**
 * Get MSE worker capability report — surfaced in startup diagnostics
 * so the backend can profile what each device can do.
 */
export function getMSEWorkerCapabilityReport() {
  return {
    mseInWorkers: isMSEInWorkersSupported(),
    transferableStreams: isTransferableStreamsSupported(),
    sharedArrayBuffer: typeof SharedArrayBuffer !== "undefined",
    atomics: typeof Atomics !== "undefined",
    offscreenCanvas: typeof OffscreenCanvas !== "undefined",
  };
}
