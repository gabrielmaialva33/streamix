const COPY = {
  connecting: "Conectando…",
  preparing: "Preparando o vídeo…",
  slow: "Quase lá…",
  reconnecting: "Reconectando…",
  playing: "",
};

/** Presentation follows decoded frames, never just a manifest or metadata event. */
export class PlaybackStartupController {
  constructor({
    root,
    video,
    cover = null,
    timerApi = globalThis,
    onFrame = () => {},
    onMark = () => {},
  }) {
    Object.assign(this, { root, video, timerApi, onFrame, onMark });
    this.hasFrame = false;
    this.awaitingFrame = false;
    this.destroyed = false;
    this.frameId = null;
    this.generation = 0;
    this.slowTimer = null;
    this.playingSeen = false;
    this.listeners = [];
    this.text = root.querySelector("[data-player-stage-text]");
    const document = root.ownerDocument;
    const loading = root.querySelector("#loading-indicator");
    if (!this.text && loading && document) {
      this.text = document.createElement("span");
      this.text.setAttribute("data-player-stage-text", "");
      loading.appendChild(this.text);
    }
    const poster = root.dataset.playerPoster || video?.poster || cover;
    if (poster && document) {
      this.cover = document.createElement("img");
      this.cover.setAttribute("data-player-startup-cover", "");
      this.cover.setAttribute("aria-hidden", "true");
      this.cover.alt = "";
      this.cover.src = poster;
      Object.assign(this.cover.style, {
        position: "absolute",
        inset: "0",
        width: "100%",
        height: "100%",
        objectFit: "cover",
        filter: "blur(16px) brightness(0.4)",
        pointerEvents: "none",
        zIndex: "10",
      });
      root.prepend(this.cover);
    }
    this.listen("loadedmetadata", () => this.preparing("metadata"));
    this.listen("play", () => this.onMark("play"));
    this.listen("playing", () => {
      this.playingSeen = true;
      this.fallbackFrame();
    });
    this.listen("timeupdate", () => this.fallbackFrame());
  }

  listen(event, handler) {
    this.video?.addEventListener(event, handler);
    this.listeners.push([event, handler]);
  }

  begin() {
    if (this.destroyed) return;
    this.hasFrame = false;
    this.setStage("connecting");
    this.attach();
    this.timerApi.clearTimeout(this.slowTimer);
    this.slowTimer = this.timerApi.setTimeout(() => {
      if (this.awaitingFrame && this.root.dataset.playerStage !== "reconnecting")
        this.setStage("slow");
    }, 4_000);
  }

  attach({ native = true } = {}) {
    if (this.destroyed) return;
    this.cancelFrame();
    this.awaitingFrame = true;
    this.root.dataset.playerAwaitingFrame = "true";
    this.playingSeen = false;
    this.native = native;
    if (this.cover && !this.hasFrame) this.cover.hidden = false;
    if (native && this.video?.requestVideoFrameCallback) {
      const generation = this.generation;
      this.frameId = this.video.requestVideoFrameCallback(() => {
        if (generation !== this.generation || this.destroyed) return;
        this.frameId = null;
        this.presented();
      });
    }
  }

  preparing(mark = "manifest") {
    if (this.destroyed) return;
    this.onMark(mark);
    if (this.awaitingFrame && !["slow", "reconnecting"].includes(this.root.dataset.playerStage))
      this.setStage("preparing");
  }

  fallbackFrame() {
    if (!this.native || this.video?.requestVideoFrameCallback) return;
    if (
      this.playingSeen &&
      !this.video.paused &&
      this.video.currentTime > 0 &&
      this.video.readyState >= 2
    )
      this.presented();
  }

  // Canvas engines have no HTMLVideoElement frame callback. Their time/render tick is the fallback.
  canvasProgress(seconds, playing) {
    if (!this.native && playing && seconds > 0) this.presented();
  }

  presented() {
    if (this.destroyed || !this.awaitingFrame) return;
    this.awaitingFrame = false;
    this.hasFrame = true;
    this.root.dataset.playerAwaitingFrame = "false";
    this.timerApi.clearTimeout(this.slowTimer);
    if (this.cover) this.cover.hidden = true;
    this.setStage("playing");
    this.onFrame();
  }

  recover() {
    if (this.destroyed) return;
    this.setStage("reconnecting");
    if (!this.awaitingFrame) this.attach({ native: this.native });
  }

  setStage(stage) {
    this.root.dataset.playerStage = stage;
    if (this.text) this.text.textContent = COPY[stage];
  }

  cancelFrame() {
    this.generation += 1;
    if (this.frameId !== null) this.video?.cancelVideoFrameCallback?.(this.frameId);
    this.frameId = null;
  }

  stop() {
    this.cancelFrame();
    this.awaitingFrame = false;
    this.root.dataset.playerAwaitingFrame = "false";
    this.timerApi.clearTimeout(this.slowTimer);
  }

  destroy() {
    this.stop();
    this.destroyed = true;
    for (const [event, handler] of this.listeners) this.video?.removeEventListener(event, handler);
    this.cover?.remove();
  }
}
