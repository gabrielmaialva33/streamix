/**
 * Cast Manager - Chromecast and AirPlay integration
 *
 * Provides unified API for casting to external devices:
 * - Google Chromecast (Cast SDK)
 * - Apple AirPlay (native WebKit support)
 *
 * Features:
 * - Device discovery and selection
 * - Media playback control on cast devices
 * - Session management and reconnection
 * - Fallback for unsupported browsers
 */

// Cast states
export const CastState = {
  NO_DEVICES: 'no_devices',
  NOT_CONNECTED: 'not_connected',
  CONNECTING: 'connecting',
  CONNECTED: 'connected',
  ERROR: 'error'
};

// Cast types
export const CastType = {
  CHROMECAST: 'chromecast',
  AIRPLAY: 'airplay',
  NONE: 'none'
};

/**
 * CastManager class
 *
 * Manages casting to Chromecast and AirPlay devices
 */
export class CastManager {
  constructor(options = {}) {
    this.options = {
      receiverApplicationId: options.receiverApplicationId || chrome?.cast?.media?.DEFAULT_MEDIA_RECEIVER_APP_ID,
      onStateChange: options.onStateChange || (() => {}),
      onDevicesAvailable: options.onDevicesAvailable || (() => {}),
      onError: options.onError || (() => {}),
      ...options
    };

    this.state = CastState.NO_DEVICES;
    this.castType = CastType.NONE;
    this.session = null;
    this.mediaSession = null;
    this.videoElement = null;
    this.currentMedia = null;

    // Feature detection
    this.chromecastAvailable = false;
    this.airplayAvailable = false;

    this._detectCapabilities();
  }

  /**
   * Detect available casting capabilities
   */
  _detectCapabilities() {
    // Check for AirPlay support (Safari/WebKit)
    this.airplayAvailable = 'webkitShowPlaybackTargetPicker' in HTMLVideoElement.prototype ||
                            window.WebKitPlaybackTargetAvailabilityEvent !== undefined;

    // Chromecast requires the Cast SDK to be loaded
    this.chromecastAvailable = typeof chrome !== 'undefined' &&
                                typeof chrome.cast !== 'undefined';

    if (this.chromecastAvailable) {
      this._initializeChromecast();
    }

    if (this.airplayAvailable || this.chromecastAvailable) {
      this._updateState(CastState.NOT_CONNECTED);
      this.options.onDevicesAvailable({
        chromecast: this.chromecastAvailable,
        airplay: this.airplayAvailable
      });
    }
  }

  /**
   * Initialize Chromecast SDK
   */
  _initializeChromecast() {
    if (!this.chromecastAvailable) return;

    const sessionRequest = new chrome.cast.SessionRequest(this.options.receiverApplicationId);
    const apiConfig = new chrome.cast.ApiConfig(
      sessionRequest,
      this._onSessionDiscovered.bind(this),
      this._onReceiverStatusChange.bind(this)
    );

    chrome.cast.initialize(apiConfig,
      () => {
        console.log('[CastManager] Chromecast initialized');
      },
      (error) => {
        console.error('[CastManager] Chromecast init error:', error);
        this.chromecastAvailable = false;
      }
    );
  }

  /**
   * Handle discovered session (for reconnection)
   */
  _onSessionDiscovered(session) {
    console.log('[CastManager] Session discovered:', session.sessionId);
    this.session = session;
    this.castType = CastType.CHROMECAST;
    this._updateState(CastState.CONNECTED);
  }

  /**
   * Handle receiver status changes
   */
  _onReceiverStatusChange(availability) {
    if (availability === chrome.cast.ReceiverAvailability.AVAILABLE) {
      this._updateState(CastState.NOT_CONNECTED);
    } else {
      this._updateState(CastState.NO_DEVICES);
    }
  }

  /**
   * Update cast state and notify listeners
   */
  _updateState(newState) {
    if (this.state !== newState) {
      this.state = newState;
      this.options.onStateChange(newState, this.castType);
    }
  }

  /**
   * Check if any casting is available
   */
  isAvailable() {
    return this.chromecastAvailable || this.airplayAvailable;
  }

  /**
   * Check if currently casting
   */
  isCasting() {
    return this.state === CastState.CONNECTED;
  }

  /**
   * Get current cast type
   */
  getCastType() {
    return this.castType;
  }

  /**
   * Get current state
   */
  getState() {
    return this.state;
  }

  /**
   * Attach to a video element for AirPlay support
   */
  attachVideo(videoElement) {
    this.videoElement = videoElement;

    if (this.airplayAvailable && videoElement) {
      // Listen for AirPlay availability
      videoElement.addEventListener('webkitplaybacktargetavailabilitychanged', (event) => {
        if (event.availability === 'available') {
          this.airplayAvailable = true;
          this._updateState(CastState.NOT_CONNECTED);
        }
      });

      // Listen for AirPlay connection changes
      videoElement.addEventListener('webkitcurrentplaybacktargetiswirelesschanged', (event) => {
        if (videoElement.webkitCurrentPlaybackTargetIsWireless) {
          this.castType = CastType.AIRPLAY;
          this._updateState(CastState.CONNECTED);
        } else {
          this.castType = CastType.NONE;
          this._updateState(CastState.NOT_CONNECTED);
        }
      });
    }
  }

  /**
   * Request cast (shows device picker)
   */
  async requestCast(preferredType = null) {
    // Prefer AirPlay on Safari, Chromecast on Chrome
    const type = preferredType || (this.airplayAvailable && /Safari/.test(navigator.userAgent) && !/Chrome/.test(navigator.userAgent)
      ? CastType.AIRPLAY
      : CastType.CHROMECAST);

    if (type === CastType.AIRPLAY && this.airplayAvailable) {
      return this._requestAirPlay();
    } else if (type === CastType.CHROMECAST && this.chromecastAvailable) {
      return this._requestChromecast();
    } else {
      throw new Error('No casting method available');
    }
  }

  /**
   * Request AirPlay connection
   */
  _requestAirPlay() {
    return new Promise((resolve, reject) => {
      if (!this.videoElement) {
        reject(new Error('No video element attached'));
        return;
      }

      if (this.videoElement.webkitShowPlaybackTargetPicker) {
        this.videoElement.webkitShowPlaybackTargetPicker();
        // AirPlay picker is async, we'll know about connection via event
        resolve();
      } else {
        reject(new Error('AirPlay not supported'));
      }
    });
  }

  /**
   * Request Chromecast connection
   */
  _requestChromecast() {
    return new Promise((resolve, reject) => {
      if (!this.chromecastAvailable) {
        reject(new Error('Chromecast not available'));
        return;
      }

      this._updateState(CastState.CONNECTING);

      chrome.cast.requestSession(
        (session) => {
          this.session = session;
          this.castType = CastType.CHROMECAST;
          this._updateState(CastState.CONNECTED);

          // Set up session update listener
          session.addUpdateListener((isAlive) => {
            if (!isAlive) {
              this._onSessionEnded();
            }
          });

          resolve(session);
        },
        (error) => {
          console.error('[CastManager] Failed to connect:', error);
          this._updateState(CastState.NOT_CONNECTED);
          this.options.onError(error);
          reject(error);
        }
      );
    });
  }

  /**
   * Load media on Chromecast
   */
  async loadMedia(mediaInfo) {
    if (!this.isCasting()) {
      throw new Error('Not connected to any cast device');
    }

    this.currentMedia = mediaInfo;

    if (this.castType === CastType.CHROMECAST) {
      return this._loadChromecastMedia(mediaInfo);
    }

    // AirPlay uses the attached video element directly
    return Promise.resolve();
  }

  /**
   * Load media on Chromecast device
   */
  _loadChromecastMedia(mediaInfo) {
    return new Promise((resolve, reject) => {
      const { url, contentType, metadata } = mediaInfo;

      const mediaDetails = new chrome.cast.media.MediaInfo(url, contentType || 'video/mp4');

      if (metadata) {
        const meta = new chrome.cast.media.GenericMediaMetadata();
        meta.title = metadata.title || '';
        meta.subtitle = metadata.subtitle || '';
        meta.images = metadata.images || [];
        mediaDetails.metadata = meta;
      }

      const request = new chrome.cast.media.LoadRequest(mediaDetails);
      request.autoplay = true;

      this.session.loadMedia(request,
        (mediaSession) => {
          this.mediaSession = mediaSession;
          console.log('[CastManager] Media loaded on Chromecast');
          resolve(mediaSession);
        },
        (error) => {
          console.error('[CastManager] Failed to load media:', error);
          this.options.onError(error);
          reject(error);
        }
      );
    });
  }

  /**
   * Play current media
   */
  play() {
    if (this.castType === CastType.CHROMECAST && this.mediaSession) {
      this.mediaSession.play(null, () => {}, (err) => console.error(err));
    }
  }

  /**
   * Pause current media
   */
  pause() {
    if (this.castType === CastType.CHROMECAST && this.mediaSession) {
      this.mediaSession.pause(null, () => {}, (err) => console.error(err));
    }
  }

  /**
   * Seek to position (seconds)
   */
  seek(position) {
    if (this.castType === CastType.CHROMECAST && this.mediaSession) {
      const request = new chrome.cast.media.SeekRequest();
      request.currentTime = position;
      this.mediaSession.seek(request, () => {}, (err) => console.error(err));
    }
  }

  /**
   * Set volume (0-1)
   */
  setVolume(volume) {
    if (this.castType === CastType.CHROMECAST && this.session) {
      this.session.setReceiverVolumeLevel(volume, () => {}, (err) => console.error(err));
    }
  }

  /**
   * Stop casting and disconnect
   */
  stopCasting() {
    if (this.castType === CastType.CHROMECAST && this.session) {
      this.session.stop(
        () => this._onSessionEnded(),
        (err) => console.error('[CastManager] Stop error:', err)
      );
    } else if (this.castType === CastType.AIRPLAY) {
      // AirPlay doesn't have a direct disconnect API
      // User must disconnect from the device picker
      this._onSessionEnded();
    }
  }

  /**
   * Handle session ended
   */
  _onSessionEnded() {
    this.session = null;
    this.mediaSession = null;
    this.castType = CastType.NONE;
    this._updateState(CastState.NOT_CONNECTED);
  }

  /**
   * Get current playback info from cast device
   */
  getPlaybackInfo() {
    if (this.castType === CastType.CHROMECAST && this.mediaSession) {
      return {
        currentTime: this.mediaSession.getEstimatedTime(),
        duration: this.mediaSession.media?.duration || 0,
        playerState: this.mediaSession.playerState,
        volume: this.session?.receiver?.volume?.level || 1
      };
    }
    return null;
  }

  /**
   * Clean up resources
   */
  destroy() {
    this.stopCasting();
    this.videoElement = null;
  }
}

/**
 * Factory function to create CastManager instance
 */
export function createCastManager(options = {}) {
  return new CastManager(options);
}

/**
 * Check if casting is supported in the current browser
 */
export function isCastingSupported() {
  const hasAirPlay = 'webkitShowPlaybackTargetPicker' in HTMLVideoElement.prototype ||
                     window.WebKitPlaybackTargetAvailabilityEvent !== undefined;
  const hasChromecast = typeof chrome !== 'undefined' && typeof chrome.cast !== 'undefined';

  return hasAirPlay || hasChromecast;
}

/**
 * Load Chromecast SDK dynamically
 * Call this early in your application to enable Chromecast support
 */
export function loadChromecastSDK() {
  return new Promise((resolve, reject) => {
    // Check if already loaded
    if (typeof chrome !== 'undefined' && typeof chrome.cast !== 'undefined') {
      resolve();
      return;
    }

    // Check if script is already in the DOM
    if (document.querySelector('script[src*="cast_sender"]')) {
      // Wait for it to load
      window.__onGCastApiAvailable = (isAvailable) => {
        if (isAvailable) resolve();
        else reject(new Error('Cast API not available'));
      };
      return;
    }

    // Load the SDK
    const script = document.createElement('script');
    script.src = 'https://www.gstatic.com/cv/js/sender/v1/cast_sender.js?loadCastFramework=1';
    script.async = true;

    window.__onGCastApiAvailable = (isAvailable) => {
      if (isAvailable) {
        console.log('[CastManager] Chromecast SDK loaded');
        resolve();
      } else {
        reject(new Error('Cast API not available'));
      }
    };

    script.onerror = () => reject(new Error('Failed to load Cast SDK'));
    document.head.appendChild(script);
  });
}

export default CastManager;
