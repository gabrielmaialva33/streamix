/**
 * Tizen SDK Integration Module
 * Provides unified interface for Tizen TV native APIs
 */
/* globals tizen, webapis */

var TizenSDK = (function() {
  'use strict';

  // Check if running on Tizen
  var isTizen = typeof tizen !== 'undefined';
  var hasWebapis = typeof webapis !== 'undefined';

  // Registered key codes for TV remote
  var TV_KEYS = {
    // Navigation
    LEFT: 37,
    UP: 38,
    RIGHT: 39,
    DOWN: 40,
    ENTER: 13,

    // Samsung TV specific
    BACK: 10009,
    EXIT: 10182,

    // Media controls
    PLAY: 415,
    PAUSE: 19,
    STOP: 413,
    REWIND: 412,
    FAST_FORWARD: 417,

    // Color buttons
    RED: 403,
    GREEN: 404,
    YELLOW: 405,
    BLUE: 406,

    // Channel
    CHANNEL_UP: 427,
    CHANNEL_DOWN: 428,

    // Volume (usually handled by system)
    VOLUME_UP: 447,
    VOLUME_DOWN: 448,
    VOLUME_MUTE: 449,

    // Number keys
    NUM_0: 48,
    NUM_1: 49,
    NUM_2: 50,
    NUM_3: 51,
    NUM_4: 52,
    NUM_5: 53,
    NUM_6: 54,
    NUM_7: 55,
    NUM_8: 56,
    NUM_9: 57,

    // Info
    INFO: 457,
    MENU: 18,
    GUIDE: 458,

    // Media extra
    RECORD: 416,
    PREVIOUS: 10232,
    NEXT: 10233
  };

  // Keys that need to be registered with inputdevice API
  var REGISTER_KEYS = [
    'MediaPlay', 'MediaPause', 'MediaStop', 'MediaRewind', 'MediaFastForward',
    'MediaRecord', 'MediaTrackPrevious', 'MediaTrackNext',
    'ColorF0Red', 'ColorF1Green', 'ColorF2Yellow', 'ColorF3Blue',
    'ChannelUp', 'ChannelDown', 'Info', 'Guide',
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9'
  ];

  /**
   * Initialize Tizen SDK
   */
  function init() {
    if (!isTizen) {
      console.log('[TizenSDK] Not running on Tizen, using browser fallback');
      return false;
    }

    console.log('[TizenSDK] Initializing...');

    // Register TV remote keys
    registerKeys();

    // Setup visibility change handler for app lifecycle
    setupVisibilityHandler();

    // Keep screen on during playback
    setScreenSaver(false);

    console.log('[TizenSDK] Initialized successfully');
    return true;
  }

  /**
   * Register TV remote keys
   */
  function registerKeys() {
    if (!isTizen) { return; }

    try {
      var inputDevice = tizen.tvinputdevice;

      for (var i = 0; i < REGISTER_KEYS.length; i++) {
        var key = REGISTER_KEYS[i];
        try {
          inputDevice.registerKey(key);
        } catch (e) {
          // Key might not be supported on this device
          console.warn('[TizenSDK] Could not register key: ' + key);
        }
      }

      console.log('[TizenSDK] Remote keys registered');
    } catch (error) {
      console.error('[TizenSDK] Error registering keys:', error);
    }
  }

  /**
   * Unregister TV remote keys
   */
  function unregisterKeys() {
    if (!isTizen) { return; }

    try {
      var inputDevice = tizen.tvinputdevice;

      for (var i = 0; i < REGISTER_KEYS.length; i++) {
        var key = REGISTER_KEYS[i];
        try {
          inputDevice.unregisterKey(key);
        } catch (e) {
          // Ignore
        }
      }
    } catch (error) {
      console.error('[TizenSDK] Error unregistering keys:', error);
    }
  }

  /**
   * Setup visibility change handler for app lifecycle
   */
  function setupVisibilityHandler() {
    document.addEventListener('visibilitychange', function() {
      if (document.hidden) {
        // App moved to background
        console.log('[TizenSDK] App moved to background');
        var bgEvent = document.createEvent('CustomEvent');
        bgEvent.initCustomEvent('tizen:background', true, false, null);
        document.dispatchEvent(bgEvent);
      } else {
        // App moved to foreground
        console.log('[TizenSDK] App moved to foreground');
        var fgEvent = document.createEvent('CustomEvent');
        fgEvent.initCustomEvent('tizen:foreground', true, false, null);
        document.dispatchEvent(fgEvent);
      }
    });
  }

  /**
   * Set screen saver state
   */
  function setScreenSaver(enabled) {
    if (!isTizen) { return; }

    try {
      if (enabled) {
        webapis.appcommon.setScreenSaver(webapis.appcommon.AppCommonScreenSaverState.SCREEN_SAVER_ON);
      } else {
        webapis.appcommon.setScreenSaver(webapis.appcommon.AppCommonScreenSaverState.SCREEN_SAVER_OFF);
      }
    } catch (error) {
      console.warn('[TizenSDK] Could not set screen saver:', error);
    }
  }

  /**
   * Exit the application
   */
  function exit() {
    if (isTizen) {
      try {
        tizen.application.getCurrentApplication().exit();
      } catch (error) {
        console.error('[TizenSDK] Error exiting app:', error);
      }
    } else {
      // Browser fallback - just close window or go back
      window.close();
    }
  }

  /**
   * Get device info
   */
  function getDeviceInfo() {
    if (!hasWebapis) {
      return {
        model: 'Browser',
        firmware: 'N/A',
        duid: 'browser-dev'
      };
    }

    try {
      return {
        model: webapis.productinfo.getModel() || 'Unknown',
        firmware: webapis.productinfo.getFirmware() || 'Unknown',
        duid: webapis.productinfo.getDuid() || 'unknown'
      };
    } catch (error) {
      console.error('[TizenSDK] Error getting device info:', error);
      return {
        model: 'Unknown',
        firmware: 'Unknown',
        duid: 'unknown'
      };
    }
  }

  /**
   * Get network state
   */
  function getNetworkState() {
    if (!hasWebapis) {
      return {
        connected: navigator.onLine,
        type: 'unknown'
      };
    }

    try {
      var networkType = webapis.network.getActiveConnectionType();
      var types = {
        0: 'disconnected',
        1: 'wifi',
        2: 'cellular',
        3: 'ethernet'
      };

      return {
        connected: networkType > 0,
        type: types[networkType] || 'unknown'
      };
    } catch (error) {
      return {
        connected: navigator.onLine,
        type: 'unknown'
      };
    }
  }

  // ============ AVPlay Video Player ============

  var AVPlayer = (function() {
    var isReady = false;
    var isPrepared = false;
    var currentState = 'NONE';
    var listeners = {};

    /**
     * Open a video URL
     */
    function open(url) {
      if (!hasWebapis || !webapis.avplay) {
        console.log('[AVPlay] Not available, using HTML5 video');
        return false;
      }

      try {
        webapis.avplay.open(url);
        isReady = true;
        currentState = 'IDLE';
        return true;
      } catch (error) {
        console.error('[AVPlay] Error opening:', error);
        return false;
      }
    }

    /**
     * Prepare the player
     */
    function prepare(callback) {
      if (!hasWebapis || !webapis.avplay) {
        if (callback) { callback(); }
        return;
      }

      try {
        webapis.avplay.prepareAsync(function() {
          isPrepared = true;
          currentState = 'READY';
          if (callback) { callback(); }
        }, function(error) {
          console.error('[AVPlay] Prepare error:', error);
          emit('error', error);
        });
      } catch (error) {
        console.error('[AVPlay] Error preparing:', error);
      }
    }

    /**
     * Set display area
     */
    function setDisplay(x, y, width, height) {
      if (!hasWebapis || !webapis.avplay) { return; }

      try {
        webapis.avplay.setDisplayRect(x, y, width, height);
      } catch (error) {
        console.error('[AVPlay] Error setting display:', error);
      }
    }

    /**
     * Play video
     */
    function play() {
      if (!hasWebapis || !webapis.avplay) { return false; }

      try {
        webapis.avplay.play();
        currentState = 'PLAYING';
        return true;
      } catch (error) {
        console.error('[AVPlay] Error playing:', error);
        return false;
      }
    }

    /**
     * Pause video
     */
    function pause() {
      if (!hasWebapis || !webapis.avplay) { return; }

      try {
        webapis.avplay.pause();
        currentState = 'PAUSED';
      } catch (error) {
        console.error('[AVPlay] Error pausing:', error);
      }
    }

    /**
     * Stop video
     */
    function stop() {
      if (!hasWebapis || !webapis.avplay) { return; }

      try {
        webapis.avplay.stop();
        currentState = 'IDLE';
      } catch (error) {
        console.error('[AVPlay] Error stopping:', error);
      }
    }

    /**
     * Close player
     */
    function close() {
      if (!hasWebapis || !webapis.avplay) { return; }

      try {
        webapis.avplay.close();
        isReady = false;
        isPrepared = false;
        currentState = 'NONE';
      } catch (error) {
        console.error('[AVPlay] Error closing:', error);
      }
    }

    /**
     * Seek to position (milliseconds)
     */
    function seek(position) {
      if (!hasWebapis || !webapis.avplay) { return; }

      try {
        webapis.avplay.seekTo(position, function() {
          emit('seeked', position);
        }, function(error) {
          console.error('[AVPlay] Seek error:', error);
        });
      } catch (error) {
        console.error('[AVPlay] Error seeking:', error);
      }
    }

    /**
     * Jump forward/backward (seconds)
     */
    function jumpTo(seconds) {
      if (!hasWebapis || !webapis.avplay) { return; }

      try {
        var current = webapis.avplay.getCurrentTime();
        var newPos = Math.max(0, current + (seconds * 1000));
        seek(newPos);
      } catch (error) {
        console.error('[AVPlay] Error jumping:', error);
      }
    }

    /**
     * Get current position (milliseconds)
     */
    function getCurrentTime() {
      if (!hasWebapis || !webapis.avplay) { return 0; }

      try {
        return webapis.avplay.getCurrentTime();
      } catch (error) {
        return 0;
      }
    }

    /**
     * Get duration (milliseconds)
     */
    function getDuration() {
      if (!hasWebapis || !webapis.avplay) { return 0; }

      try {
        return webapis.avplay.getDuration();
      } catch (error) {
        return 0;
      }
    }

    /**
     * Get current state
     */
    function getState() {
      if (!hasWebapis || !webapis.avplay) { return 'NONE'; }

      try {
        return webapis.avplay.getState();
      } catch (error) {
        return currentState;
      }
    }

    /**
     * Set listener
     */
    function setListener(listenerObj) {
      if (!hasWebapis || !webapis.avplay) { return; }

      try {
        webapis.avplay.setListener(listenerObj);
      } catch (error) {
        console.error('[AVPlay] Error setting listener:', error);
      }
    }

    /**
     * Event emitter
     */
    function on(event, callback) {
      if (!listeners[event]) { listeners[event] = []; }
      listeners[event].push(callback);
    }

    function off(event, callback) {
      if (!listeners[event]) { return; }
      var filtered = [];
      for (var i = 0; i < listeners[event].length; i++) {
        if (listeners[event][i] !== callback) {
          filtered.push(listeners[event][i]);
        }
      }
      listeners[event] = filtered;
    }

    function emit(event, data) {
      if (!listeners[event]) { return; }
      for (var i = 0; i < listeners[event].length; i++) {
        listeners[event][i](data);
      }
    }

    /**
     * Check if AVPlay is available
     */
    function isAvailable() {
      return hasWebapis && typeof webapis.avplay !== 'undefined';
    }

    return {
      isAvailable: isAvailable,
      open: open,
      prepare: prepare,
      setDisplay: setDisplay,
      play: play,
      pause: pause,
      stop: stop,
      close: close,
      seek: seek,
      jumpTo: jumpTo,
      getCurrentTime: getCurrentTime,
      getDuration: getDuration,
      getState: getState,
      setListener: setListener,
      on: on,
      off: off
    };
  })();

  // Public API
  return {
    isTizen: isTizen,
    hasWebapis: hasWebapis,
    TV_KEYS: TV_KEYS,
    init: init,
    registerKeys: registerKeys,
    unregisterKeys: unregisterKeys,
    setScreenSaver: setScreenSaver,
    exit: exit,
    getDeviceInfo: getDeviceInfo,
    getNetworkState: getNetworkState,
    AVPlayer: AVPlayer
  };
})();

// Export globally
window.TizenSDK = TizenSDK;
