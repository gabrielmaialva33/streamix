import shaka from "shaka-player";

export interface Player {
  isPaused(): boolean;
  getDuration(): number;
  getCurrentPosition(): number;
  play(): void;
  pause(): void;
  stop(): void;
  seek(time: number): void;
}

export class CommonPlayer implements Player {
  private _player: shaka.Player | null = null;
  private _videoElement: HTMLVideoElement;

  constructor(videoElement?: HTMLVideoElement) {
    this._videoElement = videoElement || this.createVideoElement();
    this.createPlayer();
  }

  private createVideoElement(): HTMLVideoElement {
    const video = document.createElement("video");
    video.style.position = "absolute";
    video.style.top = "0";
    video.style.left = "0";
    video.style.width = "100%";
    video.style.height = "100%";
    document.body.appendChild(video);
    return video;
  }

  private createPlayer() {
    this._player = new shaka.Player(this._videoElement);
    this._player.addEventListener("error", event => console.error("Shaka Player error:", event));
  }

  async load(streamUrl: string, autoPlay = false, startTime?: number): Promise<void> {
    if (!this._player) throw new Error("Player is not initialized.");

    try {
      await this._player.load(streamUrl, startTime);
      if (autoPlay) this._videoElement.play();
      console.log("Stream loaded successfully");
    } catch (error) {
      console.error("Failed to load stream:", error);
      throw error;
    }
  }

  isPaused(): boolean {
    return this._videoElement.paused;
  }

  getDuration(): number {
    return this._videoElement.duration;
  }

  getCurrentPosition(): number {
    return this._videoElement.currentTime;
  }

  togglePlayPause(): void {
    if (this._videoElement.paused) this._videoElement.play();
    else this._videoElement.pause();
  }

  play(): void {
    this._videoElement.play();
  }

  stop(): void {
    this._player?.unload();
    this.createPlayer();
  }

  pause(): void {
    this._videoElement.pause();
  }

  seek(time: number): void {
    this._videoElement.currentTime += time;
  }
}
