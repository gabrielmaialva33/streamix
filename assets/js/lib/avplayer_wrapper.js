/**
 * AVPlayer Wrapper for libmedia
 *
 * Provides software decoding for codecs not supported by browsers,
 * including AC3, DTS, EAC3 (Dolby Digital).
 */

// CDN base URL for WASM files
// Note: The npm package doesn't include the decode WASMs, so we use the GitHub repo directly
const WASM_CDN_BASE = 'https://cdn.jsdelivr.net/gh/zhaohappy/libmedia@latest/dist';

// Local paths for bundled assets
const LOCAL_AVPLAYER_PATH = '/avplayer';

// Codec IDs from @libmedia/avutil
const AVCodecID = {
  // Audio codecs
  AV_CODEC_ID_AAC: 86018,
  AV_CODEC_ID_MP3: 86017,
  AV_CODEC_ID_FLAC: 86028,
  AV_CODEC_ID_OPUS: 86076,
  AV_CODEC_ID_VORBIS: 86021,
  AV_CODEC_ID_AC3: 86019,
  AV_CODEC_ID_EAC3: 86056,
  AV_CODEC_ID_DTS: 86020, // DCA
  AV_CODEC_ID_PCM_S16LE: 65536,
  AV_CODEC_ID_PCM_S24LE: 65540,
  // Video codecs
  AV_CODEC_ID_H264: 27,
  AV_CODEC_ID_HEVC: 173,
  AV_CODEC_ID_VP9: 167,
  AV_CODEC_ID_VP8: 139,
  AV_CODEC_ID_AV1: 225,
  AV_CODEC_ID_MPEG4: 12,
  AV_CODEC_ID_MPEG2VIDEO: 2,
};

// Map codec IDs to WASM file names
const DECODER_WASM_MAP = {
  // Audio decoders
  [AVCodecID.AV_CODEC_ID_AAC]: 'aac',
  [AVCodecID.AV_CODEC_ID_MP3]: 'mp3',
  [AVCodecID.AV_CODEC_ID_FLAC]: 'flac',
  [AVCodecID.AV_CODEC_ID_OPUS]: 'opus',
  [AVCodecID.AV_CODEC_ID_VORBIS]: 'vorbis',
  [AVCodecID.AV_CODEC_ID_AC3]: 'ac3',
  [AVCodecID.AV_CODEC_ID_EAC3]: 'eac3',
  [AVCodecID.AV_CODEC_ID_DTS]: 'dca', // DTS uses dca (DTS Coherent Acoustics)
  [AVCodecID.AV_CODEC_ID_PCM_S16LE]: 'pcm',
  [AVCodecID.AV_CODEC_ID_PCM_S24LE]: 'pcm',
  // Video decoders
  [AVCodecID.AV_CODEC_ID_H264]: 'h264',
  [AVCodecID.AV_CODEC_ID_HEVC]: 'hevc',
  [AVCodecID.AV_CODEC_ID_VP9]: 'vp9',
  [AVCodecID.AV_CODEC_ID_VP8]: 'vp8',
  [AVCodecID.AV_CODEC_ID_AV1]: 'av1',
  [AVCodecID.AV_CODEC_ID_MPEG4]: 'mpeg4',
  [AVCodecID.AV_CODEC_ID_MPEG2VIDEO]: 'mpeg2video',
};

// PCM codec range
const PCM_CODEC_START = 65536;
const PCM_CODEC_END = 65572;
const ADPCM_CODEC_START = 69632;
const ADPCM_CODEC_END = 69683;

/**
 * Get WASM URL for a given codec
 */
function getWasmUrl(type, codecId) {
  // Handle resampler and stretchpitcher FIRST - they don't need a codecId
  if (type === 'resampler') {
    return `${WASM_CDN_BASE}/resample/resample-atomic.wasm`;
  }
  if (type === 'stretchpitcher') {
    return `${WASM_CDN_BASE}/stretchpitch/stretchpitch-atomic.wasm`;
  }

  // For decoder type, we need a valid codecId
  if (type !== 'decoder') {
    console.warn(`[AVPlayerWrapper] Unknown WASM type: ${type}`);
    return null;
  }

  // Handle PCM range
  if (codecId >= PCM_CODEC_START && codecId <= PCM_CODEC_END) {
    return `${WASM_CDN_BASE}/decode/pcm-atomic.wasm`;
  }
  // Handle ADPCM range
  if (codecId >= ADPCM_CODEC_START && codecId <= ADPCM_CODEC_END) {
    return `${WASM_CDN_BASE}/decode/adpcm-atomic.wasm`;
  }

  const codecName = DECODER_WASM_MAP[codecId];
  if (!codecName) {
    console.warn(`[AVPlayerWrapper] Unknown codec ID: ${codecId}`);
    return null;
  }

  // Use -atomic version for better compatibility (doesn't require SharedArrayBuffer)
  return `${WASM_CDN_BASE}/decode/${codecName}-atomic.wasm`;
}

/**
 * Load a script dynamically
 */
function loadScript(src, id = null) {
  return new Promise((resolve, reject) => {
    // Check if already loaded
    if (id && document.getElementById(id)) {
      resolve();
      return;
    }

    const script = document.createElement('script');
    if (id) script.id = id;
    script.src = src;
    script.onload = () => resolve();
    script.onerror = () => reject(new Error(`Failed to load script: ${src}`));
    document.head.appendChild(script);
  });
}

/**
 * Configure webpack public path for dynamic imports
 * AVPlayer UMD bundle loads chunks dynamically and needs to know the base path
 */
function configureWebpackPublicPath() {
  // Set the public path for webpack chunk loading
  // This ensures dynamic imports resolve to the correct directory
  if (typeof __webpack_public_path__ === 'undefined') {
    window.__webpack_public_path__ = `${LOCAL_AVPLAYER_PATH}/`;
  }
}

/**
 * AVPlayer wrapper class
 */
export class AVPlayerWrapper {
  constructor(options = {}) {
    this.container = options.container;
    this.onError = options.onError || (() => {});
    this.onReady = options.onReady || (() => {});
    this.onPlay = options.onPlay || (() => {});
    this.onPause = options.onPause || (() => {});
    this.onTimeUpdate = options.onTimeUpdate || (() => {});
    this.onEnded = options.onEnded || (() => {});

    this.player = null;
    this.isReady = false;
    this.currentUrl = null;
    this._destroyed = false;

    // Internal state for tracking playback
    this._playing = false;
    this._currentTimeMs = 0;
    this._durationMs = 0;
    this._volume = 1;
  }

  /**
   * Initialize the AVPlayer with all required dependencies
   */
  async init() {
    if (this.player || this._destroyed) {
      return;
    }

    try {
      console.log('[AVPlayerWrapper] Initializing...');

      // Step 1: Configure webpack public path for dynamic chunk loading
      configureWebpackPublicPath();

      // Step 2: Load cheap-polyfill.js FIRST
      await loadScript(`${LOCAL_AVPLAYER_PATH}/cheap-polyfill.js`, 'cheap-polyfill');
      console.log('[AVPlayerWrapper] Loaded cheap-polyfill.js');

      // Step 3: Configure polyfill URL for BigInt fallback
      if (typeof BigInt === 'undefined' || BigInt === Number) {
        window.CHEAP_POLYFILL_URL = `${LOCAL_AVPLAYER_PATH}/cheap-polyfill.js`;
      }

      // Step 4: Load AVPlayer main script
      await loadScript(`${LOCAL_AVPLAYER_PATH}/avplayer.js`);
      console.log('[AVPlayerWrapper] Loaded avplayer.js');

      if (!window.AVPlayer) {
        throw new Error('AVPlayer not found after loading script');
      }

      // Step 5: Initialize AudioContext (required for Web Audio API playback)
      if (!window.AVPlayer.audioContext) {
        window.AVPlayer.audioContext = new (window.AudioContext || window.webkitAudioContext)();
        // Create a dummy source to unlock audio on mobile
        window.AVPlayer.audioContext.createBufferSource();
        console.log('[AVPlayerWrapper] AudioContext initialized');
      }

      // Step 6: Create the player instance
      this.player = new window.AVPlayer({
        container: this.container,
        getWasm: (type, codecId) => {
          const url = getWasmUrl(type, codecId);
          console.log(`[AVPlayerWrapper] getWasm: type=${type}, codecId=${codecId}, url=${url}`);
          return url;
        },
        enableHardware: true, // Use hardware acceleration when available
        enableWebCodecs: true, // Use WebCodecs API when available
        loop: false,
      });

      // Set up event listeners
      this.setupEventListeners();

      this.isReady = true;
      this.onReady();

      console.log('[AVPlayerWrapper] Initialized successfully');
    } catch (error) {
      console.error('[AVPlayerWrapper] Failed to initialize:', error);
      this.onError(error);
      throw error;
    }
  }

  /**
   * Set up event listeners for the player
   */
  setupEventListeners() {
    if (!this.player) return;

    this.player.on('playing', () => {
      console.log('[AVPlayerWrapper] Playing');
      this._playing = true;
      this.onPlay();
    });

    this.player.on('pause', () => {
      console.log('[AVPlayerWrapper] Paused');
      this._playing = false;
      this.onPause();
    });

    this.player.on('ended', () => {
      console.log('[AVPlayerWrapper] Ended');
      this._playing = false;
      this.onEnded();
    });

    this.player.on('error', (error) => {
      console.error('[AVPlayerWrapper] Error event:', error);
      this.onError(error);
    });

    // Add more event listeners for debugging
    this.player.on('loadstart', () => {
      console.log('[AVPlayerWrapper] Event: loadstart');
    });

    this.player.on('progress', (progress) => {
      console.log('[AVPlayerWrapper] Event: progress', progress);
    });

    this.player.on('canplay', () => {
      console.log('[AVPlayerWrapper] Event: canplay');
    });

    this.player.on('waiting', () => {
      console.log('[AVPlayerWrapper] Event: waiting');
    });

    this.player.on('stalled', () => {
      console.log('[AVPlayerWrapper] Event: stalled');
    });

    this.player.on('time', (time) => {
      // time is in milliseconds
      this._currentTimeMs = typeof time === 'bigint' ? Number(time) : time;
      this.onTimeUpdate(this._currentTimeMs / 1000);
    });

    this.player.on('loaded', () => {
      console.log('[AVPlayerWrapper] Loaded');
      // Try to get duration from formatContext streams
      this._cacheDuration();
    });

    this.player.on('seeking', () => {
      console.log('[AVPlayerWrapper] Seeking');
    });

    this.player.on('seeked', () => {
      console.log('[AVPlayerWrapper] Seeked');
    });
  }

  /**
   * Cache the duration from the player's format context
   */
  _cacheDuration() {
    try {
      if (this.player && this.player.formatContext && this.player.formatContext.streams) {
        const streams = this.player.formatContext.streams;
        for (let i = 0; i < streams.length; i++) {
          const stream = streams[i];
          if (stream && stream.duration) {
            // Duration is in stream's timeBase, convert to milliseconds
            // For now, assume it's already in a usable format
            const durationValue = typeof stream.duration === 'bigint'
              ? Number(stream.duration)
              : stream.duration;
            if (durationValue > 0) {
              // Duration might be in various units, try to detect
              // If it's very large (> 1000000), it's likely in microseconds
              if (durationValue > 1000000000) {
                this._durationMs = durationValue / 1000; // microseconds to ms
              } else if (durationValue > 1000000) {
                this._durationMs = durationValue; // already in ms
              } else {
                this._durationMs = durationValue * 1000; // seconds to ms
              }
              console.log('[AVPlayerWrapper] Cached duration:', this._durationMs, 'ms');
              break;
            }
          }
        }
      }
    } catch (e) {
      console.warn('[AVPlayerWrapper] Could not cache duration:', e);
    }
  }

  /**
   * Load a video URL
   * @param {string} url - The video URL to load
   * @param {object} options - Load options
   * @param {string} options.ext - File extension (e.g., 'mkv', 'mp4') to force format detection
   */
  async load(url, options = {}) {
    if (this._destroyed) {
      throw new Error('Player has been destroyed');
    }

    if (!this.player) {
      await this.init();
    }

    this.currentUrl = url;
    console.log('[AVPlayerWrapper] Loading:', url);
    console.log('[AVPlayerWrapper] Load options:', options);
    console.log('[AVPlayerWrapper] Container:', this.container);
    console.log('[AVPlayerWrapper] Player instance:', this.player);

    try {
      console.log('[AVPlayerWrapper] Calling player.load()...');

      // Create a timeout promise to detect if load hangs
      const timeoutPromise = new Promise((_, reject) => {
        setTimeout(() => reject(new Error('Load timeout after 30 seconds')), 30000);
      });

      // Build load options for AVPlayer
      // ext: forces format detection for URLs without extensions (like /api/stream/proxy?token=...)
      const loadOptions = {};
      if (options.ext) {
        loadOptions.ext = options.ext;
        console.log('[AVPlayerWrapper] Forcing format detection with ext:', options.ext);
      }

      const loadResult = this.player.load(url, loadOptions);
      console.log('[AVPlayerWrapper] load() returned:', loadResult);

      if (loadResult && typeof loadResult.then === 'function') {
        // Race between load and timeout
        await Promise.race([loadResult, timeoutPromise]);
      }

      console.log('[AVPlayerWrapper] Load complete, container innerHTML:', this.container?.innerHTML?.substring(0, 200));
    } catch (error) {
      console.error('[AVPlayerWrapper] Load error:', error);
      console.error('[AVPlayerWrapper] Error stack:', error?.stack);
      this.onError(error);
      throw error;
    }
  }

  /**
   * Start playback
   */
  async play() {
    if (!this.player) {
      throw new Error('Player not initialized');
    }

    console.log('[AVPlayerWrapper] play() called, _playing:', this._playing);
    console.log('[AVPlayerWrapper] AudioContext state:', window.AVPlayer?.audioContext?.state);

    try {
      // Resume AudioContext if suspended (required after user interaction)
      if (window.AVPlayer?.audioContext?.state === 'suspended') {
        console.log('[AVPlayerWrapper] Resuming AudioContext...');
        await window.AVPlayer.audioContext.resume();
        console.log('[AVPlayerWrapper] AudioContext resumed, new state:', window.AVPlayer?.audioContext?.state);
      }
      console.log('[AVPlayerWrapper] Calling player.play()...');
      const playResult = this.player.play();
      console.log('[AVPlayerWrapper] player.play() returned:', playResult);
      if (playResult && typeof playResult.then === 'function') {
        await playResult;
      }
      // Manually set _playing in case event doesn't fire
      this._playing = true;
      console.log('[AVPlayerWrapper] play() completed successfully, _playing:', this._playing);
      // Manually call onPlay since event might not fire on resume
      this.onPlay();
    } catch (error) {
      console.error('[AVPlayerWrapper] Play error:', error);
      this.onError(error);
      throw error;
    }
  }

  /**
   * Pause playback
   */
  async pause() {
    if (this.player) {
      console.log('[AVPlayerWrapper] pause() called, _playing:', this._playing);
      const pauseResult = this.player.pause();
      console.log('[AVPlayerWrapper] player.pause() returned:', pauseResult);
      if (pauseResult && typeof pauseResult.then === 'function') {
        await pauseResult;
      }
      // Manually set _playing in case event doesn't fire
      this._playing = false;
      console.log('[AVPlayerWrapper] pause() completed, _playing:', this._playing);
      // Manually call onPause since event might not fire
      this.onPause();
    }
  }

  /**
   * Stop playback
   */
  async stop() {
    if (this.player) {
      await this.player.stop();
    }
  }

  /**
   * Seek to a specific time in seconds
   */
  async seek(time) {
    if (this.player) {
      // AVPlayer seek uses milliseconds as int64
      const timeMs = Math.floor(time * 1000);
      console.log('[AVPlayerWrapper] Seeking to', time, 'seconds (', timeMs, 'ms)');
      try {
        await this.player.seek(BigInt(timeMs));
      } catch (e) {
        // Fallback without BigInt if needed
        console.warn('[AVPlayerWrapper] Seek with BigInt failed, trying without:', e);
        await this.player.seek(timeMs);
      }
    }
  }

  /**
   * Set volume (0-1)
   */
  setVolume(volume) {
    this._volume = volume;
    if (this.player) {
      this.player.setVolume(volume);
    }
  }

  /**
   * Get current playback time in seconds
   */
  getCurrentTime() {
    // Use cached time from 'time' event (more reliable)
    if (this._currentTimeMs > 0) {
      return this._currentTimeMs / 1000;
    }

    // Fallback: try to get from player.currentTime property
    if (this.player) {
      try {
        const time = this.player.currentTime;
        if (time !== undefined && time !== null) {
          const timeValue = typeof time === 'bigint' ? Number(time) : time;
          // currentTime is in milliseconds
          return timeValue / 1000;
        }
      } catch (e) {
        // Ignore errors
      }
    }

    return 0;
  }

  /**
   * Get total duration in seconds
   */
  getDuration() {
    // Use cached duration (most reliable)
    if (this._durationMs > 0) {
      return this._durationMs / 1000;
    }

    // Fallback: try to get from player.duration property
    if (this.player) {
      try {
        const duration = this.player.duration;
        if (duration !== undefined && duration !== null) {
          const durationValue = typeof duration === 'bigint' ? Number(duration) : duration;
          // duration is in milliseconds
          return durationValue / 1000;
        }
      } catch (e) {
        // Ignore errors
      }
    }

    return 0;
  }

  /**
   * Check if currently playing
   */
  isPlaying() {
    return this._playing;
  }

  /**
   * Destroy the player and cleanup
   */
  async destroy() {
    if (this._destroyed) return;

    this._destroyed = true;

    if (this.player) {
      try {
        await this.player.destroy();
      } catch (e) {
        console.warn('[AVPlayerWrapper] Error during destroy:', e);
      }
      this.player = null;
    }

    // Cleanup AudioContext to free memory
    // Only close if we created it and no other AVPlayer instances are using it
    if (window.AVPlayer?.audioContext && !window._avplayerInstanceCount) {
      try {
        const audioCtx = window.AVPlayer.audioContext;
        if (audioCtx.state !== 'closed') {
          // Suspend first, then close
          if (audioCtx.state === 'running') {
            await audioCtx.suspend();
          }
          await audioCtx.close();
          window.AVPlayer.audioContext = null;
          console.log('[AVPlayerWrapper] AudioContext closed');
        }
      } catch (e) {
        console.warn('[AVPlayerWrapper] Error closing AudioContext:', e);
      }
    }

    this.isReady = false;
    this._playing = false;
    this._currentTimeMs = 0;
    this._durationMs = 0;
    console.log('[AVPlayerWrapper] Destroyed');
  }
}

/**
 * Detect if a video element has audio issues
 * Returns true if audio is not working properly
 */
export function detectAudioIssue(videoElement) {
  return new Promise((resolve) => {
    // Quick timeout - don't wait too long
    const timeout = setTimeout(() => {
      console.log('[detectAudioIssue] Timeout - assuming no issue');
      resolve(false);
    }, 5000);

    // Method 1: Check webkitAudioDecodedByteCount (Chrome/Safari)
    if ('webkitAudioDecodedByteCount' in videoElement) {
      const checkAudio = () => {
        // Wait for video to play for a bit
        if (videoElement.currentTime > 0.5) {
          clearTimeout(timeout);
          const hasAudio = videoElement.webkitAudioDecodedByteCount > 0;
          console.log(`[detectAudioIssue] webkitAudioDecodedByteCount: ${videoElement.webkitAudioDecodedByteCount}, hasAudio: ${hasAudio}`);
          resolve(!hasAudio);
        } else if (!videoElement.paused) {
          requestAnimationFrame(checkAudio);
        }
      };

      if (videoElement.readyState >= 3 && !videoElement.paused) {
        setTimeout(checkAudio, 300);
      } else {
        const onPlaying = () => {
          videoElement.removeEventListener('playing', onPlaying);
          setTimeout(checkAudio, 300);
        };
        videoElement.addEventListener('playing', onPlaying);
      }
      return;
    }

    // Method 2: Check audioTracks (Firefox)
    if (videoElement.audioTracks) {
      const checkTracks = () => {
        clearTimeout(timeout);
        const hasAudioTracks = videoElement.audioTracks.length > 0;
        console.log(`[detectAudioIssue] audioTracks count: ${videoElement.audioTracks.length}`);
        resolve(!hasAudioTracks);
      };

      if (videoElement.readyState >= 1) {
        checkTracks();
      } else {
        videoElement.addEventListener('loadedmetadata', checkTracks, { once: true });
      }
      return;
    }

    // Fallback: assume no issue
    clearTimeout(timeout);
    resolve(false);
  });
}

/**
 * Check if browser natively supports a specific audio codec
 */
export function canPlayAudioCodec(codec) {
  const video = document.createElement('video');
  const mimeTypes = {
    'ac3': 'audio/ac3',
    'eac3': 'audio/eac3',
    'dts': 'audio/dts',
    'aac': 'audio/aac',
    'mp3': 'audio/mpeg',
    'opus': 'audio/opus',
    'flac': 'audio/flac',
    'vorbis': 'audio/ogg; codecs="vorbis"',
  };

  const mimeType = mimeTypes[codec.toLowerCase()];
  if (!mimeType) return true; // Unknown codec, assume supported

  const result = video.canPlayType(mimeType);
  return result === 'probably' || result === 'maybe';
}

export default AVPlayerWrapper;
