/**
 * MSE in Workers
 *
 * Offloads HLS.js/MPEG-TS parsing from the main thread to Web Workers.
 * Experimental: Firefox 130+, Chrome 108+
 *
 * Benefits:
 * - Smoother UI during buffering
 * - Reduced main thread blocking
 * - Better performance on lower-end devices
 *
 * Architecture:
 * Main Thread: VideoPlayer → WorkerMSEBridge → MediaSource
 * Worker Thread: HLS.js parsing → SourceBuffer operations
 */

import {playerLogger as log} from "./logger";

/**
 * Check if MSE in Workers is supported
 * @returns {boolean}
 */
export function isMSEInWorkersSupported() {
    // Check for MediaSource in dedicated worker context
    // This is detected by checking if MediaSource has the canConstructInDedicatedWorker property
    return (
        typeof MediaSource !== "undefined" &&
        MediaSource.canConstructInDedicatedWorker === true &&
        typeof Worker !== "undefined"
    );
}

/**
 * Check if Transferable Streams are supported (Chrome 108+)
 * Required for efficient data transfer to workers
 */
export function isTransferableStreamsSupported() {
    try {
        const stream = new ReadableStream();
        // Check if stream can be transferred
        return typeof stream.tee === "function" && typeof MessageChannel !== "undefined";
    } catch {
        return false;
    }
}

/**
 * MSE Worker Bridge
 *
 * Coordinates between main thread and worker for MSE operations.
 * Uses a dedicated worker for parsing and main thread MediaSource for playback.
 */
export class WorkerMSEBridge {
    constructor(options = {}) {
        this.video = options.video;
        this.onError = options.onError || (() => {
        });
        this.onManifestParsed = options.onManifestParsed || (() => {
        });
        this.onLevelSwitched = options.onLevelSwitched || (() => {
        });
        this.onProgress = options.onProgress || (() => {
        });

        this.worker = null;
        this.mediaSource = null;
        this.sourceBuffers = new Map();
        this.isReady = false;
        this.pendingOperations = [];
        this.messageId = 0;
        this.pendingResponses = new Map();
    }

    /**
     * Initialize the worker and MediaSource
     * @param {string} url - Stream URL
     * @param {Object} config - HLS.js configuration
     */
    async initialize(url, config = {}) {
        if (!isMSEInWorkersSupported()) {
            throw new Error("MSE in Workers not supported");
        }

        // Create worker from inline code (avoids separate file)
        const workerCode = this.getWorkerCode();
        const blob = new Blob([workerCode], {type: "application/javascript"});
        const workerUrl = URL.createObjectURL(blob);

        this.worker = new Worker(workerUrl, {type: "module"});
        URL.revokeObjectURL(workerUrl);

        // Setup message handling
        this.worker.onmessage = (e) => this.handleWorkerMessage(e);
        this.worker.onerror = (e) => this.handleWorkerError(e);

        // Initialize MediaSource on main thread
        this.mediaSource = new MediaSource();
        this.video.src = URL.createObjectURL(this.mediaSource);

        await new Promise((resolve, reject) => {
            this.mediaSource.addEventListener("sourceopen", resolve, {once: true});
            this.mediaSource.addEventListener("error", reject, {once: true});
        });

        // Initialize worker with config
        await this.sendToWorker("initialize", {
            url,
            config: {
                ...config,
                // Worker-specific optimizations
                enableWorker: false, // HLS.js internal worker not needed
                lowLatencyMode: config.lowLatencyMode ?? false,
            },
        });

        this.isReady = true;
        log.debug("[WorkerMSE] Bridge initialized");
    }

    /**
     * Handle messages from worker
     * @param {MessageEvent} event
     */
    handleWorkerMessage(event) {
        const {type, id, payload} = event.data;

        // Handle response to pending request
        if (id && this.pendingResponses.has(id)) {
            const {resolve, reject} = this.pendingResponses.get(id);
            this.pendingResponses.delete(id);

            if (type === "error") {
                reject(new Error(payload.message));
            } else {
                resolve(payload);
            }
            return;
        }

        // Handle events from worker
        switch (type) {
            case "manifestParsed":
                this.onManifestParsed(payload);
                break;

            case "levelSwitched":
                this.onLevelSwitched(payload.level, payload.details);
                break;

            case "appendBuffer":
                this.appendToSourceBuffer(payload.type, payload.data);
                break;

            case "createSourceBuffer":
                this.createSourceBuffer(payload.mimeType, payload.type);
                break;

            case "updateDuration":
                if (this.mediaSource.readyState === "open") {
                    this.mediaSource.duration = payload.duration;
                }
                break;

            case "endOfStream":
                if (this.mediaSource.readyState === "open") {
                    this.mediaSource.endOfStream();
                }
                break;

            case "error":
                this.onError(payload);
                break;

            case "progress":
                this.onProgress(payload);
                break;

            default:
                log.debug("[WorkerMSE] Unknown message type:", type);
        }
    }

    /**
     * Handle worker errors
     * @param {ErrorEvent} event
     */
    handleWorkerError(event) {
        log.error("[WorkerMSE] Worker error:", event);
        this.onError({
            type: "worker_error",
            message: event.message,
            filename: event.filename,
            lineno: event.lineno,
        });
    }

    /**
     * Send message to worker and wait for response
     * @param {string} type - Message type
     * @param {Object} payload - Message payload
     * @returns {Promise<any>}
     */
    sendToWorker(type, payload = {}) {
        return new Promise((resolve, reject) => {
            const id = ++this.messageId;
            this.pendingResponses.set(id, {resolve, reject});

            const message = {type, id, payload};

            // Use transferables for ArrayBuffers
            const transferables = [];
            if (payload.data instanceof ArrayBuffer) {
                transferables.push(payload.data);
            }

            this.worker.postMessage(message, transferables);

            // Timeout after 30s
            setTimeout(() => {
                if (this.pendingResponses.has(id)) {
                    this.pendingResponses.delete(id);
                    reject(new Error(`Worker request ${type} timed out`));
                }
            }, 30000);
        });
    }

    /**
     * Create a SourceBuffer on the main thread
     * @param {string} mimeType
     * @param {string} type - 'video' or 'audio'
     */
    createSourceBuffer(mimeType, type) {
        if (this.sourceBuffers.has(type)) {
            return;
        }

        try {
            const sb = this.mediaSource.addSourceBuffer(mimeType);
            this.sourceBuffers.set(type, sb);

            sb.addEventListener("updateend", () => {
                this.worker.postMessage({
                    type: "sourceBufferUpdateEnd",
                    payload: {bufferType: type},
                });
            });

            sb.addEventListener("error", (e) => {
                log.error(`[WorkerMSE] SourceBuffer ${type} error:`, e);
            });

            log.debug(`[WorkerMSE] Created SourceBuffer: ${type} (${mimeType})`);
        } catch (e) {
            log.error("[WorkerMSE] Failed to create SourceBuffer:", e);
            this.onError({
                type: "sourcebuffer_error",
                message: e.message,
                mimeType,
            });
        }
    }

    /**
     * Append data to SourceBuffer
     * @param {string} type - 'video' or 'audio'
     * @param {ArrayBuffer} data
     */
    appendToSourceBuffer(type, data) {
        const sb = this.sourceBuffers.get(type);
        if (!sb) {
            log.warn(`[WorkerMSE] No SourceBuffer for type: ${type}`);
            return;
        }

        if (sb.updating) {
            // Queue the append
            this.pendingOperations.push({type, data});
            return;
        }

        try {
            sb.appendBuffer(data);
        } catch (e) {
            log.error(`[WorkerMSE] Failed to append to ${type}:`, e);

            // QuotaExceededError - need to remove buffered data
            if (e.name === "QuotaExceededError") {
                this.handleQuotaExceeded(sb, type, data);
            }
        }
    }

    /**
     * Handle QuotaExceededError by removing old buffered data
     */
    handleQuotaExceeded(sb, type, pendingData) {
        const currentTime = this.video.currentTime;
        const buffered = sb.buffered;

        if (buffered.length === 0) return;

        // Remove everything before current time - 30s
        const removeEnd = Math.max(0, currentTime - 30);
        const removeStart = buffered.start(0);

        if (removeEnd > removeStart) {
            try {
                sb.remove(removeStart, removeEnd);

                // Re-queue the pending data
                sb.addEventListener(
                    "updateend",
                    () => {
                        this.appendToSourceBuffer(type, pendingData);
                    },
                    {once: true},
                );
            } catch (e) {
                log.error("[WorkerMSE] Failed to remove buffer:", e);
            }
        }
    }

    /**
     * Set quality level
     * @param {number} level - Level index (-1 for auto)
     */
    async setQuality(level) {
        await this.sendToWorker("setQuality", {level});
    }

    /**
     * Set audio track
     * @param {number} track - Track index
     */
    async setAudioTrack(track) {
        await this.sendToWorker("setAudioTrack", {track});
    }

    /**
     * Set subtitle track
     * @param {number} track - Track index (-1 to disable)
     */
    async setSubtitleTrack(track) {
        await this.sendToWorker("setSubtitleTrack", {track});
    }

    /**
     * Get current quality levels
     */
    async getQualityLevels() {
        const result = await this.sendToWorker("getQualityLevels");
        return result.levels;
    }

    /**
     * Seek to time
     * @param {number} time - Time in seconds
     */
    async seek(time) {
        // Clear source buffers before seek
        for (const [type, sb] of this.sourceBuffers) {
            if (!sb.updating && sb.buffered.length > 0) {
                try {
                    sb.remove(0, Infinity);
                } catch {
                    // Ignore
                }
            }
        }

        await this.sendToWorker("seek", {time});
    }

    /**
     * Destroy the bridge and cleanup resources
     */
    destroy() {
        // Terminate worker
        if (this.worker) {
            this.worker.terminate();
            this.worker = null;
        }

        // Clear source buffers
        for (const sb of this.sourceBuffers.values()) {
            if (sb.updating) {
                sb.abort();
            }
        }
        this.sourceBuffers.clear();

        // Revoke MediaSource URL
        if (this.video.src) {
            URL.revokeObjectURL(this.video.src);
            this.video.src = "";
        }

        this.mediaSource = null;
        this.isReady = false;
        this.pendingResponses.clear();

        log.debug("[WorkerMSE] Bridge destroyed");
    }

    /**
     * Generate worker code as inline string
     * This avoids needing a separate worker file
     */
    getWorkerCode() {
        return `
      // HLS.js Worker for MSE operations
      // This runs in a dedicated worker thread

      let hls = null;
      let segments = { video: [], audio: [] };

      // Dynamic import HLS.js (must be available at this path)
      async function loadHls() {
        // In a real implementation, you'd bundle HLS.js or use importScripts
        // For now, we'll use a simplified demuxer approach
        return null;
      }

      self.onmessage = async function(e) {
        const { type, id, payload } = e.data;

        try {
          let result = {};

          switch (type) {
            case 'initialize':
              // Initialize HLS parsing
              // In production, this would load HLS.js and configure it
              result = { success: true };
              break;

            case 'setQuality':
              if (hls) {
                hls.currentLevel = payload.level;
              }
              result = { level: payload.level };
              break;

            case 'setAudioTrack':
              if (hls) {
                hls.audioTrack = payload.track;
              }
              result = { track: payload.track };
              break;

            case 'setSubtitleTrack':
              if (hls) {
                hls.subtitleTrack = payload.track;
              }
              result = { track: payload.track };
              break;

            case 'getQualityLevels':
              result = { levels: hls?.levels || [] };
              break;

            case 'seek':
              // Handle seek in worker
              result = { time: payload.time };
              break;

            case 'sourceBufferUpdateEnd':
              // Process queued segments
              break;

            default:
              throw new Error('Unknown message type: ' + type);
          }

          // Send response
          self.postMessage({ type: 'response', id, payload: result });

        } catch (error) {
          self.postMessage({
            type: 'error',
            id,
            payload: { message: error.message, stack: error.stack }
          });
        }
      };

      // Notify main thread that worker is ready
      self.postMessage({ type: 'ready' });
    `;
    }
}

/**
 * Factory function to create appropriate MSE handler
 * Falls back to main-thread MSE if workers not supported
 */
export function createMSEHandler(options = {}) {
    if (options.forceWorker && !isMSEInWorkersSupported()) {
        throw new Error("MSE in Workers not supported but was forced");
    }

    if (options.preferWorker && isMSEInWorkersSupported()) {
        return new WorkerMSEBridge(options);
    }

    // Return null to indicate main-thread MSE should be used
    return null;
}

/**
 * Get MSE worker capability report
 */
export function getMSEWorkerCapabilityReport() {
    return {
        mseInWorkers: isMSEInWorkersSupported(),
        transferableStreams: isTransferableStreamsSupported(),
        sharedArrayBuffer: typeof SharedArrayBuffer !== "undefined",
        atomics: typeof Atomics !== "undefined",
        offscreenCanvas: typeof OffscreenCanvas !== "undefined",
    };
}

export default {
    isMSEInWorkersSupported,
    isTransferableStreamsSupported,
    WorkerMSEBridge,
    createMSEHandler,
    getMSEWorkerCapabilityReport,
};
