/**
 * PlayerManager - Singleton manager for video playback
 *
 * Following LightningJS/Blits best practices:
 * - Separation of concerns between player logic and UI
 * - Singleton pattern for consistent state across components
 * - Abstraction layer supporting both AVPlay (Tizen) and HTML5
 *
 * @see https://mlangendijk.medium.com/video-playback-with-blits-lightning3-38a2e247d871
 * @see https://developer.samsung.com/smarttv/develop/guides/multimedia/media-playback/using-avplay.html
 */

declare const webapis: any;
declare const tizen: any;

export interface PlayerState {
  playing: boolean;
  currentTime: number;
  duration: number;
  buffering: boolean;
  error: string | null;
  ready: boolean;
}

export interface PlayerCallbacks {
  onStateChange?: (state: PlayerState) => void;
  onComplete?: () => void;
  onError?: (error: string) => void;
}

type PlayerBackend = 'avplay' | 'html5';

// Check if running on Tizen with AVPlay support
const isTizen = typeof window !== 'undefined' &&
  (typeof (window as any).tizen !== 'undefined' || navigator.userAgent.includes('Tizen'));

const hasAVPlay = (): boolean => {
  try {
    return isTizen && typeof webapis !== 'undefined' && typeof webapis.avplay !== 'undefined';
  } catch {
    return false;
  }
};

// Singleton state
let videoElement: HTMLVideoElement | null = null;
let hlsInstance: any = null;
let timeUpdateInterval: number | null = null;
let callbacks: PlayerCallbacks = {};
let currentBackend: PlayerBackend | null = null;
let isInitialized = false;

// Store original styles to restore on destroy
let originalAppStyle: string | null = null;
let originalRootStyle: string | null = null;

let state: PlayerState = {
  playing: false,
  currentTime: 0,
  duration: 0,
  buffering: true,
  error: null,
  ready: false,
};

const updateState = (updates: Partial<PlayerState>) => {
  state = { ...state, ...updates };
  callbacks.onStateChange?.(state);
};

// AVPlay callbacks for Tizen
const avplayCallbacks = {
  onbufferingstart: () => {
    console.log('[AVPlay] Buffering started');
    updateState({ buffering: true });
  },
  onbufferingprogress: (percent: number) => {
    console.log('[AVPlay] Buffering:', percent + '%');
  },
  onbufferingcomplete: () => {
    console.log('[AVPlay] Buffering complete');
    updateState({ buffering: false });
  },
  oncurrentplaytime: (currentTime: number) => {
    updateState({ currentTime: currentTime / 1000 });
  },
  onstreamcompleted: () => {
    console.log('[AVPlay] Stream completed');
    callbacks.onComplete?.();
  },
  onevent: (eventType: string, eventData: string) => {
    console.log('[AVPlay] Event:', eventType, eventData);
  },
  onerror: (eventType: string) => {
    console.error('[AVPlay] Error:', eventType);
    updateState({ error: `Playback error: ${eventType}`, buffering: false });
    callbacks.onError?.(`Playback error: ${eventType}`);
  },
};

/**
 * Initialize the player manager
 */
const init = async (cbs: PlayerCallbacks = {}): Promise<void> => {
  console.log('[PlayerManager] Initializing...', { isTizen, hasAVPlay: hasAVPlay() });

  callbacks = cbs;
  currentBackend = hasAVPlay() ? 'avplay' : 'html5';

  if (currentBackend === 'html5') {
    // Create video element
    videoElement = document.createElement('video');
    videoElement.id = 'player-video';
    videoElement.style.cssText = `
      position: fixed;
      top: 0;
      left: 0;
      width: 100%;
      height: 100%;
      background: #000;
      z-index: 100000;
    `;
    videoElement.playsInline = true;
    videoElement.autoplay = true;

    // Position Lightning canvas on top of video for controls overlay
    // Use mix-blend-mode: screen to make black areas transparent (show video through)
    const appElement = document.getElementById('app');
    if (appElement) {
      originalAppStyle = appElement.getAttribute('style');
      appElement.style.cssText = `
        position: fixed !important;
        left: 0;
        top: 0;
        z-index: 100001 !important;
        pointer-events: none;
        mix-blend-mode: screen;
      `;
      // Also apply to canvas inside
      const canvas = appElement.querySelector('canvas');
      if (canvas) {
        (canvas as HTMLElement).style.mixBlendMode = 'screen';
      }
    }

    // Hide Lightning's accessibility DOM tree (blocks video with high z-index)
    const rootElement = document.getElementById('root');
    if (rootElement) {
      originalRootStyle = rootElement.getAttribute('style');
      rootElement.style.cssText = `
        position: absolute !important;
        z-index: 0 !important;
        pointer-events: none !important;
      `;
    }

    document.body.insertBefore(videoElement, document.body.firstChild);

    // Event listeners
    videoElement.addEventListener('play', () => updateState({ playing: true }));
    videoElement.addEventListener('pause', () => updateState({ playing: false }));
    videoElement.addEventListener('waiting', () => updateState({ buffering: true }));
    videoElement.addEventListener('playing', () => updateState({ buffering: false, playing: true }));
    videoElement.addEventListener('canplay', () => updateState({ buffering: false, ready: true }));
    videoElement.addEventListener('loadedmetadata', () => {
      updateState({ duration: videoElement!.duration || 0 });
    });
    videoElement.addEventListener('timeupdate', () => {
      updateState({ currentTime: videoElement!.currentTime });
    });
    videoElement.addEventListener('error', (e) => {
      console.error('[HTML5] Video error:', e);
      const error = 'Playback error';
      updateState({ error, buffering: false });
      callbacks.onError?.(error);
    });
    videoElement.addEventListener('ended', () => {
      callbacks.onComplete?.();
    });
  } else {
    // AVPlay: Start time update interval
    timeUpdateInterval = window.setInterval(() => {
      try {
        const avState = webapis.avplay.getState();
        if (avState === 'PLAYING' || avState === 'PAUSED') {
          const currentTime = webapis.avplay.getCurrentTime();
          updateState({ currentTime: currentTime / 1000 });
        }
      } catch (e) {}
    }, 1000);
  }

  isInitialized = true;
  console.log('[PlayerManager] Initialized with backend:', currentBackend);
};

/**
 * Load and play a video URL
 */
const load = async (url: string): Promise<void> => {
  if (!isInitialized) {
    throw new Error('PlayerManager not initialized. Call init() first.');
  }

  console.log('[PlayerManager] Loading URL:', url);
  updateState({ buffering: true, error: null, ready: false });

  if (currentBackend === 'avplay') {
    await loadAVPlay(url);
  } else {
    await loadHTML5(url);
  }
};

const loadAVPlay = async (url: string): Promise<void> => {
  try {
    // Close any existing player
    try {
      webapis.avplay.close();
    } catch (e) {}

    // Open the stream
    webapis.avplay.open(url);

    // Set display rect (fullscreen 1920x1080)
    webapis.avplay.setDisplayRect(0, 0, 1920, 1080);

    // Set callbacks
    webapis.avplay.setListener(avplayCallbacks);

    // For HLS streams, set streaming property
    if (url.includes('.m3u8')) {
      try {
        webapis.avplay.setStreamingProperty('ADAPTIVE_INFO', 'BITRATES=adaptive');
      } catch (e) {
        console.warn('[AVPlay] Could not set adaptive info:', e);
      }
    }

    // Prepare asynchronously (best practice - doesn't block UI)
    webapis.avplay.prepareAsync(
      () => {
        console.log('[AVPlay] Prepared, starting playback');
        const duration = webapis.avplay.getDuration();
        updateState({ duration: duration / 1000, buffering: false, ready: true });
        webapis.avplay.play();
        updateState({ playing: true });

        // Keep screen awake
        try {
          tizen.power.request('SCREEN', 'SCREEN_NORMAL');
        } catch (e) {}
      },
      (error: any) => {
        console.error('[AVPlay] Prepare error:', error);
        updateState({ error: `Prepare error: ${error}`, buffering: false });
        callbacks.onError?.(`Prepare error: ${error}`);
      }
    );
  } catch (error) {
    console.error('[AVPlay] Load error:', error);
    updateState({ error: String(error), buffering: false });
    callbacks.onError?.(String(error));
  }
};

const loadHTML5 = async (url: string): Promise<void> => {
  if (!videoElement) {
    throw new Error('Video element not created');
  }

  try {
    // Check if HLS
    if (url.includes('.m3u8')) {
      // Native HLS support (Safari, some TVs)
      if (videoElement.canPlayType('application/vnd.apple.mpegurl')) {
        console.log('[HTML5] Using native HLS');
        videoElement.src = url;
      } else {
        // Use HLS.js
        console.log('[HTML5] Using HLS.js');
        const Hls = (await import('hls.js')).default;
        if (Hls.isSupported()) {
          hlsInstance = new Hls({
            enableWorker: true,
            lowLatencyMode: false,
            maxBufferLength: 30,
            maxMaxBufferLength: 60,
          });
          hlsInstance.loadSource(url);
          hlsInstance.attachMedia(videoElement);
          hlsInstance.on(Hls.Events.MANIFEST_PARSED, () => {
            console.log('[HLS.js] Manifest parsed, playing');
            videoElement?.play().catch(e => console.warn('[HTML5] Autoplay blocked:', e));
          });
          hlsInstance.on(Hls.Events.ERROR, (_: any, data: any) => {
            console.error('[HLS.js] Error:', data);
            if (data.fatal) {
              updateState({ error: `HLS Error: ${data.type}` });
              callbacks.onError?.(`HLS Error: ${data.type}`);
            }
          });
        } else {
          updateState({ error: 'HLS not supported' });
          callbacks.onError?.('HLS not supported');
        }
      }
    } else {
      // Direct playback for MP4/other formats
      videoElement.src = url;
    }

    await videoElement.play().catch(e => console.warn('[HTML5] Autoplay blocked:', e));
  } catch (error) {
    console.error('[HTML5] Error:', error);
    updateState({ error: String(error), buffering: false });
    callbacks.onError?.(String(error));
  }
};

/**
 * Play the video
 */
const play = (): void => {
  if (currentBackend === 'avplay') {
    try {
      const avState = webapis.avplay.getState();
      if (avState === 'PAUSED' || avState === 'READY') {
        webapis.avplay.play();
        updateState({ playing: true });
      }
    } catch (e) {
      console.error('[AVPlay] Play error:', e);
    }
  } else if (videoElement) {
    videoElement.play();
  }
};

/**
 * Pause the video
 */
const pause = (): void => {
  if (currentBackend === 'avplay') {
    try {
      const avState = webapis.avplay.getState();
      if (avState === 'PLAYING') {
        webapis.avplay.pause();
        updateState({ playing: false });
      }
    } catch (e) {
      console.error('[AVPlay] Pause error:', e);
    }
  } else if (videoElement) {
    videoElement.pause();
  }
};

/**
 * Toggle play/pause
 */
const togglePlayPause = (): void => {
  if (state.playing) {
    pause();
  } else {
    play();
  }
};

/**
 * Seek by delta seconds (positive or negative)
 */
const seek = (delta: number): void => {
  if (currentBackend === 'avplay') {
    try {
      const currentTime = webapis.avplay.getCurrentTime();
      const duration = webapis.avplay.getDuration();
      const newTime = Math.max(0, Math.min(duration, currentTime + delta * 1000));
      webapis.avplay.seekTo(newTime);
    } catch (e) {
      console.error('[AVPlay] Seek error:', e);
    }
  } else if (videoElement) {
    videoElement.currentTime = Math.max(0, Math.min(state.duration, videoElement.currentTime + delta));
  }
};

/**
 * Seek to absolute position in seconds
 */
const seekTo = (position: number): void => {
  if (currentBackend === 'avplay') {
    try {
      webapis.avplay.seekTo(position * 1000);
    } catch (e) {
      console.error('[AVPlay] SeekTo error:', e);
    }
  } else if (videoElement) {
    videoElement.currentTime = Math.max(0, Math.min(state.duration, position));
  }
};

/**
 * Get current time in seconds
 */
const getCurrentTime = (): number => {
  return state.currentTime;
};

/**
 * Get duration in seconds
 */
const getDuration = (): number => {
  return state.duration;
};

/**
 * Get current player state
 */
const getState = (): PlayerState => {
  return { ...state };
};

/**
 * Destroy the player and clean up resources
 * CRITICAL: Must be called when leaving the player
 */
const destroy = async (): Promise<void> => {
  console.log('[PlayerManager] Destroying...');

  if (timeUpdateInterval) {
    clearInterval(timeUpdateInterval);
    timeUpdateInterval = null;
  }

  if (currentBackend === 'avplay') {
    try {
      webapis.avplay.stop();
      webapis.avplay.close();
      tizen.power.release('SCREEN');
    } catch (e) {}
  }

  if (hlsInstance) {
    hlsInstance.destroy();
    hlsInstance = null;
  }

  if (videoElement) {
    videoElement.pause();
    videoElement.src = '';
    videoElement.remove();
    videoElement = null;
  }

  // Restore original styles
  const appElement = document.getElementById('app');
  if (appElement && originalAppStyle !== null) {
    appElement.setAttribute('style', originalAppStyle);
  } else if (appElement) {
    appElement.removeAttribute('style');
  }

  const rootElement = document.getElementById('root');
  if (rootElement && originalRootStyle !== null) {
    rootElement.setAttribute('style', originalRootStyle);
  } else if (rootElement) {
    rootElement.removeAttribute('style');
  }

  originalAppStyle = null;
  originalRootStyle = null;

  // Reset state
  state = {
    playing: false,
    currentTime: 0,
    duration: 0,
    buffering: true,
    error: null,
    ready: false,
  };

  callbacks = {};
  currentBackend = null;
  isInitialized = false;

  console.log('[PlayerManager] Destroyed');
};

/**
 * Get the current backend type
 */
const getBackend = (): PlayerBackend | null => {
  return currentBackend;
};

export const PlayerManager = {
  init,
  load,
  play,
  pause,
  togglePlayPause,
  seek,
  seekTo,
  getCurrentTime,
  getDuration,
  getState,
  destroy,
  getBackend,
  isTizen,
  hasAVPlay,
};

export default PlayerManager;
