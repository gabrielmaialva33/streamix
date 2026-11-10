import { playerRecommendationKey } from "./player_preferences.js";

/** Learn only after a presented frame and continuous advancing playback, once per batch/engine. */
export class ProviderEngineMemory {
  constructor({
    getPlayback,
    record,
    timerApi = globalThis,
    now = () => performance.now(),
    stableMs = 5000,
  }) {
    Object.assign(this, { getPlayback, record, timerApi, now, stableMs });
    this.timer = null;
    this.recorded = new Set();
  }

  select({ providerId, streamType, engine, batchId, startedAt = this.now(), selectionReason }) {
    this.clear();
    if (this.batchId !== batchId) this.recorded.clear();
    this.batchId = batchId;
    this.startedAt = startedAt;
    this.ttffMs = null;
    const key = playerRecommendationKey({ providerId, streamType });
    this.choice =
      key && ["native", "avplayer"].includes(engine)
        ? { key, engine, streamType, selectionReason }
        : null;
  }

  frame() {
    this.ttffMs ??= Math.max(0, this.now() - this.startedAt);
    this.hasFrame = true;
    this.progress();
  }

  progress() {
    const choice = this.choice;
    const playback = this.getPlayback();
    const signature = choice && `${choice.key}:${choice.engine}`;
    if (
      !choice ||
      !this.hasFrame ||
      (choice.engine === "avplayer" && this.ttffMs > 15_000) ||
      !playback.playing ||
      this.timer !== null ||
      this.recorded.has(signature)
    )
      return;
    const from = playback.currentTime;
    const rate = Number(playback.playbackRate) > 0 ? Number(playback.playbackRate) : 1;
    // Allow coarse media clocks, but a single tick before a freeze is not stability.
    const requiredProgress = (this.stableMs / 1000) * rate * 0.8;
    const maximumProgress = (this.stableMs / 1000) * rate * 1.25 + 0.5;
    this.timer = this.timerApi.setTimeout(() => {
      this.timer = null;
      const current = this.getPlayback();
      if (
        this.choice !== choice ||
        !this.hasFrame ||
        !current.playing ||
        !(current.currentTime - from >= requiredProgress) ||
        current.currentTime - from > maximumProgress
      )
        return;
      this.recorded.add(signature);
      this.record(choice.key, choice.engine, {
        streamType: choice.streamType,
        selectionReason: choice.selectionReason,
        ttffMs: this.ttffMs,
      });
    }, this.stableMs);
  }

  pause() {
    if (this.timer !== null) this.timerApi.clearTimeout(this.timer);
    this.timer = null;
  }

  interrupt() {
    this.pause();
    this.hasFrame = false;
  }

  clear() {
    this.interrupt();
    this.choice = null;
  }
}
