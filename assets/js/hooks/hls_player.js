import Hls from "hls.js"

const HlsPlayer = {
  mounted() {
    this.video = this.el
    this.currentUrl = this.el.dataset.streamUrl
    this.watchStart = Date.now()
    this.hls = null

    this.initPlayer()
    this.setupKeyboardShortcuts()
  },

  updated() {
    const newUrl = this.el.dataset.streamUrl
    if (newUrl !== this.currentUrl) {
      this.currentUrl = newUrl
      this.loadStream(newUrl)
    }
  },

  destroyed() {
    this.cleanup()
    this.reportWatchDuration()
    this.removeKeyboardShortcuts()
  },

  initPlayer() {
    const streamUrl = this.currentUrl

    if (!streamUrl) {
      console.warn("No stream URL provided")
      return
    }

    if (Hls.isSupported()) {
      this.hls = new Hls({
        enableWorker: true,
        lowLatencyMode: true,
        backBufferLength: 90,
        maxBufferLength: 30,
        maxMaxBufferLength: 600,
        startLevel: -1,
      })

      this.hls.on(Hls.Events.ERROR, (event, data) => {
        if (data.fatal) {
          switch (data.type) {
            case Hls.ErrorTypes.NETWORK_ERROR:
              console.error("Network error, trying to recover...")
              this.hls.startLoad()
              break
            case Hls.ErrorTypes.MEDIA_ERROR:
              console.error("Media error, trying to recover...")
              this.hls.recoverMediaError()
              break
            default:
              console.error("Fatal error, cannot recover:", data)
              this.cleanup()
              break
          }
        }
      })

      this.hls.on(Hls.Events.MANIFEST_PARSED, () => {
        this.video.play().catch((e) => {
          console.log("Autoplay prevented:", e)
        })
      })

      this.loadStream(streamUrl)
    } else if (this.video.canPlayType("application/vnd.apple.mpegurl")) {
      // Native HLS support (Safari)
      this.video.src = streamUrl
      this.video.addEventListener("loadedmetadata", () => {
        this.video.play().catch((e) => {
          console.log("Autoplay prevented:", e)
        })
      })
    } else {
      console.error("HLS is not supported in this browser")
    }
  },

  loadStream(url) {
    if (this.hls) {
      this.hls.loadSource(url)
      this.hls.attachMedia(this.video)
    } else {
      this.video.src = url
    }
  },

  cleanup() {
    if (this.hls) {
      this.hls.destroy()
      this.hls = null
    }
  },

  reportWatchDuration() {
    const duration = Math.floor((Date.now() - this.watchStart) / 1000)
    if (duration > 5) {
      this.pushEvent("update_duration", { duration })
    }
  },

  setupKeyboardShortcuts() {
    this.handleKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.handleKeydown)
  },

  removeKeyboardShortcuts() {
    document.removeEventListener("keydown", this.handleKeydown)
  },

  handleKeydown(e) {
    // Ignore if typing in an input
    if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA") {
      return
    }

    switch (e.code) {
      case "Space":
        e.preventDefault()
        this.togglePlay()
        break
      case "KeyF":
        e.preventDefault()
        this.toggleFullscreen()
        break
      case "KeyM":
        e.preventDefault()
        this.toggleMute()
        break
      case "ArrowLeft":
        e.preventDefault()
        this.seek(-10)
        break
      case "ArrowRight":
        e.preventDefault()
        this.seek(10)
        break
      case "ArrowUp":
        e.preventDefault()
        this.adjustVolume(0.1)
        break
      case "ArrowDown":
        e.preventDefault()
        this.adjustVolume(-0.1)
        break
      case "Escape":
        if (document.fullscreenElement) {
          document.exitFullscreen()
        }
        break
    }
  },

  togglePlay() {
    if (this.video.paused) {
      this.video.play()
    } else {
      this.video.pause()
    }
  },

  toggleFullscreen() {
    const container = this.el.closest("#player-container") || this.el
    if (document.fullscreenElement) {
      document.exitFullscreen()
    } else {
      container.requestFullscreen().catch((e) => {
        console.log("Fullscreen error:", e)
      })
    }
  },

  toggleMute() {
    this.video.muted = !this.video.muted
  },

  seek(seconds) {
    this.video.currentTime = Math.max(0, this.video.currentTime + seconds)
  },

  adjustVolume(delta) {
    this.video.volume = Math.max(0, Math.min(1, this.video.volume + delta))
  },
}

export default HlsPlayer
