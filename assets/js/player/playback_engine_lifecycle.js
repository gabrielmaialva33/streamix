const TIMEOUT = Symbol("playback-engine-timeout");

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
