import { avplayerLogger as log } from "../core/logger.js";

// Track active audio detection to prevent AudioContext leaks during rapid zapping
let activeAudioDetection = null;

/**
 * Detect if a video element has audio issues
 * Returns true if audio is not working properly
 */
export function detectAudioIssue(videoElement) {
  return new Promise((resolve) => {
    // Quick timeout - don't wait too long
    const timeout = setTimeout(() => {
      log.debug("[detectAudioIssue] Timeout - assuming no issue");
      resolve(false);
    }, 5000);

    // Method 1: Check webkitAudioDecodedByteCount (Chrome/Safari)
    if ("webkitAudioDecodedByteCount" in videoElement) {
      const checkAudio = () => {
        // Wait for video to play for a bit
        if (videoElement.currentTime > 0.5) {
          clearTimeout(timeout);
          const hasAudio = videoElement.webkitAudioDecodedByteCount > 0;
          log.debug(
            `[detectAudioIssue] webkitAudioDecodedByteCount: ${videoElement.webkitAudioDecodedByteCount}, hasAudio: ${hasAudio}`,
          );
          resolve(!hasAudio);
        } else if (!videoElement.paused) {
          requestAnimationFrame(checkAudio);
        }
      };

      if (videoElement.readyState >= 3 && !videoElement.paused) {
        setTimeout(checkAudio, 300);
      } else {
        const onPlaying = () => {
          videoElement.removeEventListener("playing", onPlaying);
          setTimeout(checkAudio, 300);
        };
        videoElement.addEventListener("playing", onPlaying);
      }
      return;
    }

    // Method 2: Check audioTracks (Firefox)
    if (videoElement.audioTracks) {
      const checkTracks = () => {
        clearTimeout(timeout);
        const hasAudioTracks = videoElement.audioTracks.length > 0;
        log.debug(`[detectAudioIssue] audioTracks count: ${videoElement.audioTracks.length}`);
        resolve(!hasAudioTracks);
      };

      if (videoElement.readyState >= 1) {
        checkTracks();
      } else {
        videoElement.addEventListener("loadedmetadata", checkTracks, { once: true });
      }
      return;
    }

    // Method 3: Web Audio API fallback (works on all browsers)
    // Creates an AudioContext and analyzes the audio stream from the video
    detectAudioWithWebAudioAPI(videoElement)
      .then((hasAudio) => {
        clearTimeout(timeout);
        log.debug(`[detectAudioIssue] Web Audio API detection: hasAudio=${hasAudio}`);
        resolve(!hasAudio);
      })
      .catch((error) => {
        log.warn("[detectAudioIssue] Web Audio API detection failed:", error);
        clearTimeout(timeout);
        resolve(false); // Assume no issue on error
      });
  });
}

/**
 * Detect audio using Web Audio API
 * Creates an AnalyserNode to check for actual audio data in the stream
 * Supports cancellation to prevent AudioContext leaks during rapid channel switching
 */
function detectAudioWithWebAudioAPI(videoElement) {
  // Cancel any active detection to prevent AudioContext accumulation
  if (activeAudioDetection) {
    activeAudioDetection.cancel();
  }

  let cancelled = false;
  let audioContext = null;
  let source = null;
  let timeoutId = null;
  let playingHandler = null;

  const cleanup = () => {
    if (timeoutId) {
      clearTimeout(timeoutId);
      timeoutId = null;
    }
    if (playingHandler && videoElement) {
      videoElement.removeEventListener("playing", playingHandler);
      playingHandler = null;
    }
    if (source && audioContext) {
      try {
        source.disconnect();
      } catch (_e) {
        /* ignore */
      }
    }
    if (audioContext) {
      audioContext.close().catch(() => {});
      audioContext = null;
    }
  };

  const detection = {
    cancel: () => {
      cancelled = true;
      cleanup();
      log.debug("[detectAudioWithWebAudioAPI] Detection cancelled");
    },
  };

  activeAudioDetection = detection;

  return new Promise((resolve, reject) => {
    try {
      const AudioContextClass = window.AudioContext || window.webkitAudioContext;
      if (!AudioContextClass) {
        activeAudioDetection = null;
        reject(new Error("Web Audio API not supported"));
        return;
      }

      audioContext = new AudioContextClass();

      try {
        source = audioContext.createMediaElementSource(videoElement);
      } catch (e) {
        // MediaElementSource may already exist for this element
        log.warn("[detectAudioWithWebAudioAPI] Could not create MediaElementSource:", e);
        cleanup();
        activeAudioDetection = null;
        reject(e);
        return;
      }

      const analyser = audioContext.createAnalyser();
      analyser.fftSize = 256;
      const bufferLength = analyser.frequencyBinCount;
      const dataArray = new Uint8Array(bufferLength);

      // Connect: video -> analyser -> destination (speakers)
      source.connect(analyser);
      analyser.connect(audioContext.destination);

      let checkCount = 0;
      const maxChecks = 10; // Check for ~1 second

      const finishDetection = (hasAudio) => {
        if (cancelled) return;
        // Cleanup: disconnect analyser but keep audio flowing
        try {
          source.disconnect(analyser);
          source.connect(audioContext.destination);
        } catch (_e) {
          /* ignore */
        }
        audioContext.close().catch(() => {});
        audioContext = null;
        activeAudioDetection = null;
        resolve(hasAudio);
      };

      const checkForAudio = () => {
        if (cancelled) return;

        checkCount++;
        analyser.getByteFrequencyData(dataArray);

        // Check if there's any significant audio data
        let sum = 0;
        for (let i = 0; i < bufferLength; i++) {
          sum += dataArray[i];
        }
        const average = sum / bufferLength;

        // If average frequency data is above threshold, audio is present
        if (average > 5) {
          finishDetection(true);
          return;
        }

        if (checkCount < maxChecks && !videoElement.paused && !cancelled) {
          timeoutId = setTimeout(checkForAudio, 100);
        } else if (!cancelled) {
          // No audio detected after all checks
          finishDetection(false);
        }
      };

      // Start checking after a short delay to let audio buffer
      if (videoElement.readyState >= 3 && !videoElement.paused) {
        timeoutId = setTimeout(checkForAudio, 200);
      } else {
        playingHandler = () => {
          if (cancelled) return;
          videoElement.removeEventListener("playing", playingHandler);
          playingHandler = null;
          timeoutId = setTimeout(checkForAudio, 200);
        };
        videoElement.addEventListener("playing", playingHandler);
      }
    } catch (error) {
      cleanup();
      activeAudioDetection = null;
      reject(error);
    }
  });
}
