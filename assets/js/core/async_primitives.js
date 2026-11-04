// A deadline settles the caller; it does not cancel the underlying operation.
export async function withTimeout(
  value,
  {
    timeoutMs,
    timerApi = globalThis,
    onTimeout = () => {
      throw new Error("Operation timed out");
    },
  },
) {
  let timeoutId;
  try {
    return await Promise.race([
      value,
      new Promise((resolve, reject) => {
        timeoutId = timerApi.setTimeout(() => {
          try {
            resolve(onTimeout());
          } catch (error) {
            reject(error);
          }
        }, timeoutMs);
      }),
    ]);
  } finally {
    if (timeoutId !== undefined) timerApi.clearTimeout(timeoutId);
  }
}

// One pending/resolved import per loader. Rejection evicts the attempt for retry.
export function memoizeImport(load) {
  let pending;
  return () => {
    pending ||= Promise.resolve()
      .then(load)
      .catch((error) => {
        pending = null;
        throw error;
      });
    return pending;
  };
}
