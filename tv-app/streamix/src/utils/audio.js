/**
 * Audio Feedback System for TV App
 * Uses Web Audio API for low-latency synthesized sounds
 * Netflix-like subtle audio cues for navigation
 */

var AudioFeedback = (function() {
  'use strict';

  // Web Audio context
  var audioContext = null;

  // Master volume (0-1)
  var masterVolume = 0.3;

  // Enabled state
  var enabled = true;

  // Sound presets (frequency, duration, type)
  var sounds = {
    // Subtle navigation tick
    move: {
      frequency: 800,
      duration: 0.03,
      type: 'sine',
      volume: 0.15
    },
    // Soft confirmation
    select: {
      frequency: 1200,
      duration: 0.08,
      type: 'sine',
      volume: 0.25,
      sweep: 1400 // End frequency for sweep
    },
    // Gentle back sound
    back: {
      frequency: 600,
      duration: 0.06,
      type: 'sine',
      volume: 0.2,
      sweep: 400 // Sweep down
    },
    // Soft error/block sound
    error: {
      frequency: 200,
      duration: 0.1,
      type: 'triangle',
      volume: 0.15
    },
    // Focus enter section
    focusSection: {
      frequency: 1000,
      duration: 0.05,
      type: 'sine',
      volume: 0.12
    }
  };

  /**
   * Initialize audio system
   */
  function init() {
    // Create audio context on first user interaction (required by browsers)
    if (!audioContext) {
      try {
        var AudioContextClass = window.AudioContext || window.webkitAudioContext;
        if (AudioContextClass) {
          audioContext = new AudioContextClass();
          console.log('[Audio] AudioContext initialized');
        } else {
          console.warn('[Audio] Web Audio API not supported');
          enabled = false;
        }
      } catch (e) {
        console.warn('[Audio] Failed to create AudioContext:', e);
        enabled = false;
      }
    }
  }

  /**
   * Resume audio context (required after user gesture)
   */
  function resume() {
    if (audioContext && audioContext.state === 'suspended') {
      audioContext.resume().then(function() {
        console.log('[Audio] AudioContext resumed');
      });
    }
  }

  /**
   * Play a synthesized sound
   * @param {string} name - Sound name (move, select, back, error)
   */
  function play(name) {
    if (!enabled || !audioContext) {
      return;
    }

    // Resume context if suspended
    if (audioContext.state === 'suspended') {
      audioContext.resume();
    }

    var sound = sounds[name];
    if (!sound) {
      console.warn('[Audio] Unknown sound:', name);
      return;
    }

    try {
      // Create oscillator
      var oscillator = audioContext.createOscillator();
      var gainNode = audioContext.createGain();

      oscillator.type = sound.type || 'sine';
      oscillator.frequency.setValueAtTime(sound.frequency, audioContext.currentTime);

      // Apply frequency sweep if defined
      if (sound.sweep) {
        oscillator.frequency.exponentialRampToValueAtTime(
          sound.sweep,
          audioContext.currentTime + sound.duration
        );
      }

      // Volume envelope for smooth sound
      var volume = (sound.volume || 0.2) * masterVolume;
      gainNode.gain.setValueAtTime(0, audioContext.currentTime);
      gainNode.gain.linearRampToValueAtTime(volume, audioContext.currentTime + 0.005);
      gainNode.gain.linearRampToValueAtTime(0, audioContext.currentTime + sound.duration);

      // Connect nodes
      oscillator.connect(gainNode);
      gainNode.connect(audioContext.destination);

      // Play sound
      oscillator.start(audioContext.currentTime);
      oscillator.stop(audioContext.currentTime + sound.duration + 0.01);

    } catch (e) {
      console.warn('[Audio] Failed to play sound:', e);
    }
  }

  /**
   * Set master volume
   * @param {number} volume - Volume level (0-1)
   */
  function setVolume(volume) {
    masterVolume = Math.max(0, Math.min(1, volume));
  }

  /**
   * Enable or disable audio
   * @param {boolean} state - Enable state
   */
  function setEnabled(state) {
    enabled = state;
  }

  /**
   * Check if audio is enabled
   */
  function isEnabled() {
    return enabled && audioContext !== null;
  }

  /**
   * Play move/navigation sound
   */
  function playMove() {
    play('move');
  }

  /**
   * Play select/enter sound
   */
  function playSelect() {
    play('select');
  }

  /**
   * Play back navigation sound
   */
  function playBack() {
    play('back');
  }

  /**
   * Play error/block sound
   */
  function playError() {
    play('error');
  }

  // Public API
  return {
    init: init,
    resume: resume,
    play: play,
    playMove: playMove,
    playSelect: playSelect,
    playBack: playBack,
    playError: playError,
    setVolume: setVolume,
    setEnabled: setEnabled,
    isEnabled: isEnabled
  };
})();

// Export for use in other modules
window.AudioFeedback = AudioFeedback;
