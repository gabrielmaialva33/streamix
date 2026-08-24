function finiteNonNegative(value, fallback = 0) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : fallback;
}

function clampVolume(value) {
  return Math.min(1, Math.max(0, finiteNonNegative(value)));
}

function assertVideo(video) {
  if (!video || typeof video.play !== "function" || typeof video.pause !== "function") {
    throw new TypeError("MediaElementEngine requires an HTMLMediaElement-like object");
  }
}

/**
 * Playback contract for engines rendered through the shared <video> element.
 *
 * HLS.js and mpegts.js own transport attachment through StreamLoader, while
 * native playback assigns the source directly. This class intentionally does
 * not own either lifecycle yet; injected callbacks make that boundary explicit
 * and let the hook migrate transport ownership independently.
 */
export class MediaElementEngine {
  constructor({
    video,
    loadSource = (_source, _options) => undefined,
    destroySource = () => undefined,
    beforePause = () => undefined,
    beforeSeek = () => undefined,
    afterSeek = () => undefined,
  }) {
    assertVideo(video);

    this.video = video;
    this.loadSource = loadSource;
    this.destroySource = destroySource;
    this.beforePause = beforePause;
    this.beforeSeek = beforeSeek;
    this.afterSeek = afterSeek;
  }

  load(source, options = {}) {
    return this.loadSource(source, options);
  }

  play() {
    return this.video.play();
  }

  pause() {
    this.beforePause();
    return this.video.pause();
  }

  seek(seconds) {
    const target = finiteNonNegative(seconds);
    this.beforeSeek(target);
    this.video.currentTime = target;
    this.afterSeek(target);
    return target;
  }

  destroy() {
    return this.destroySource();
  }

  setVolume(volume) {
    this.video.volume = clampVolume(volume);
  }

  getCurrentTime() {
    return finiteNonNegative(this.video.currentTime);
  }

  getDuration() {
    return finiteNonNegative(this.video.duration);
  }

  isPlaying() {
    return this.video.paused === false && this.video.ended !== true;
  }

  on(event, handler) {
    this.video.addEventListener?.(event, handler);
  }

  off(event, handler) {
    this.video.removeEventListener?.(event, handler);
  }
}

export function createMediaElementEngine(options) {
  return new MediaElementEngine(options);
}
