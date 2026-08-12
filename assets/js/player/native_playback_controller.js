const READY_EVENTS = ["loadedmetadata", "canplay", "error"];
const SEEK_EVENTS = ["seeked", "timeupdate", "canplay", "error"];

export function nativePreloadMode(resumeTime = 0) {
  return resumeTime > 0 ? "metadata" : "none";
}

export function configureNativePlaybackElement(video, { resumeTime = 0 } = {}) {
  if (!video) return;

  video.autoplay = false;
  video.removeAttribute("autoplay");
  video.preload = nativePreloadMode(resumeTime);
}

function waitForMediaSignal({ video, eventNames, timerApi, timeoutMs }) {
  let finish;

  const promise = new Promise((resolve) => {
    let settled = false;

    finish = () => {
      if (settled) return;
      settled = true;
      timerApi.clearTimeout(timeout);

      for (const eventName of eventNames) {
        video.removeEventListener(eventName, finish);
      }

      resolve();
    };

    const timeout = timerApi.setTimeout(finish, timeoutMs);

    for (const eventName of eventNames) {
      video.addEventListener(eventName, finish, { once: true });
    }
  });

  return { finish: () => finish(), promise };
}

export function waitForNativeReady({ video, isCurrent, timerApi = globalThis, timeoutMs = 2_500 }) {
  if (!video || video.readyState >= 1 || !isCurrent()) {
    return Promise.resolve();
  }

  return waitForMediaSignal({
    video,
    eventNames: READY_EVENTS,
    timerApi,
    timeoutMs,
  }).promise;
}

export function waitForNativeSeek({
  video,
  targetTime,
  isCurrent,
  onSeekError = () => {},
  timerApi = globalThis,
  timeoutMs = 2_500,
}) {
  if (!video || targetTime <= 0 || !isCurrent()) {
    return Promise.resolve();
  }

  const completion = waitForMediaSignal({
    video,
    eventNames: SEEK_EVENTS,
    timerApi,
    timeoutMs,
  });

  try {
    video.currentTime = targetTime;
  } catch (error) {
    onSeekError(error);
    completion.finish();
  }

  return completion.promise;
}
