const TIMEOUT = Symbol("playback-engine-timeout");

export function resolvePlaybackResumeTime(player, fallback = 0) {
  try {
    const currentTime = Number(player?.getCurrentTime?.());
    if (Number.isFinite(currentTime) && currentTime > 0) return currentTime;
  } catch {}

  const fallbackTime = Number(fallback);
  return Number.isFinite(fallbackTime) && fallbackTime > 0 ? fallbackTime : 0;
}

export async function awaitPlaybackOperation(
  result,
  {
    timeoutMs = 30_000,
    timerApi = globalThis,
    timeoutMessage = "Playback operation timed out",
  } = {},
) {
  if (!result || typeof result.then !== "function") return result;

  let timeoutId;

  try {
    return await Promise.race([
      result,
      new Promise((_, reject) => {
        timeoutId = timerApi.setTimeout(() => reject(new Error(timeoutMessage)), timeoutMs);
      }),
    ]);
  } finally {
    if (timeoutId !== undefined) timerApi.clearTimeout(timeoutId);
  }
}

const scheduleNextTurn = (callback) => globalThis.setTimeout(callback, 0);

export function createSynchronousErrorNotifier(callback, schedule = scheduleNextTurn) {
  const reportedErrors = new Set();
  let resetScheduled = false;

  return (error) => {
    if (reportedErrors.has(error)) return false;

    reportedErrors.add(error);
    if (!resetScheduled) {
      resetScheduled = true;
      schedule(() => {
        reportedErrors.clear();
        resetScheduled = false;
      });
    }

    callback(error);
    return true;
  };
}

export class PlaybackEngineTeardownQueue {
  constructor({ onError = () => {} } = {}) {
    this.onError = onError;
    this.pending = new WeakMap();
    this.tail = Promise.resolve();
    this.busy = false;
  }

  destroy(engine) {
    if (!engine || typeof engine.destroy !== "function") return this.tail;

    const existing = this.pending.get(engine);
    if (existing) return existing;

    const run = async () => {
      try {
        await engine.destroy();
      } catch (error) {
        try {
          this.onError(error);
        } catch {}
      }
    };

    // Invoke the first teardown immediately so an async destroy() can stop
    // network/audio synchronously before its first await. Later engines wait
    // for the active teardown and cannot overlap shared AudioContext cleanup.
    const task = this.busy ? this.tail.then(run) : run();
    this.busy = true;

    this.pending.set(engine, task);
    const tail = task.finally(() => this.pending.delete(engine));
    this.tail = tail;
    tail.finally(() => {
      if (this.tail === tail) this.busy = false;
    });
    return task;
  }

  drain() {
    return this.tail;
  }
}

async function settleEngineCall(name, result, { timeoutMs, timerApi, onError }) {
  if (!result || typeof result.then !== "function") return;

  let timeoutId;

  try {
    const outcome = await Promise.race([
      result,
      new Promise((resolve) => {
        timeoutId = timerApi.setTimeout(() => resolve(TIMEOUT), timeoutMs);
      }),
    ]);

    if (outcome === TIMEOUT) {
      onError(name, new Error(`${name} timed out after ${timeoutMs}ms`));
    }
  } catch (error) {
    onError(name, error);
  } finally {
    if (timeoutId !== undefined) timerApi.clearTimeout(timeoutId);
  }
}

export async function stopThenDestroyPlaybackEngine(
  player,
  { timeoutMs = 1_000, timerApi = globalThis, onError = () => {} } = {},
) {
  if (!player) return;

  let stopResult;

  try {
    // Invoke stop before the first await. Callers intentionally do not await
    // teardown during LiveView navigation, so this is what aborts the fetch now.
    stopResult = player.stop?.();
  } catch (error) {
    onError("stop", error);
  }

  await settleEngineCall("stop", stopResult, { timeoutMs, timerApi, onError });

  let destroyResult;

  try {
    destroyResult = player.destroy?.();
  } catch (error) {
    onError("destroy", error);
  }

  await settleEngineCall("destroy", destroyResult, { timeoutMs, timerApi, onError });
}
