/**
 * WebCodecs feature detection + capability report.
 *
 * The previous version of this file shipped a `WebCodecsDecoder` and a
 * `WebCodecsRenderer` class (~280 LoC) that nothing in the app ever
 * instantiated. The audit confirmed they were dead — the only consumers
 * of this module are simple capability probes used by `codec_priority.js`
 * and `video_player.js`. Trimmed to just those.
 */

import {playerLogger as log} from "./logger";

/**
 * Check if WebCodecs API is available
 */
export function isWebCodecsSupported() {
    return (
        typeof VideoDecoder !== "undefined" &&
        typeof VideoEncoder !== "undefined" &&
        typeof VideoFrame !== "undefined"
    );
}

/**
 * Check if hardware acceleration is available for a specific codec
 * @param {string} codec - Codec string (e.g., 'avc1.42E01E', 'av01.0.01M.08')
 * @returns {Promise<{supported: boolean, hardwareAccelerated: boolean}>}
 */
export async function checkHardwareSupport(codec) {
    if (!isWebCodecsSupported()) {
        return {supported: false, hardwareAccelerated: false};
    }

    try {
        const result = await VideoDecoder.isConfigSupported({
            codec,
            hardwareAcceleration: "prefer-hardware",
            width: 1920,
            height: 1080,
        });
        return {
            supported: result.supported,
            hardwareAccelerated: result.config?.hardwareAcceleration === "prefer-hardware",
        };
    } catch (e) {
        log.debug("[WebCodecs] Hardware support check failed:", e.message);
        return {supported: false, hardwareAccelerated: false};
    }
}

/**
 * Codec configurations for WebCodecs probing
 */
export const WEBCODECS_CONFIGS = {
    h264: {
        baseline: "avc1.42E01E",
        main: "avc1.4D401E",
        high: "avc1.64001F",
        high10: "avc1.6E001F",
    },
    hevc: {
        main: "hvc1.1.6.L93.B0",
        main10: "hvc1.2.4.L120.B0",
    },
    av1: {
        main8: "av01.0.01M.08",
        main10: "av01.0.05M.10",
        high: "av01.0.08M.08",
    },
    vp9: {
        profile0: "vp09.00.10.08",
        profile2: "vp09.02.10.10",
    },
};

/**
 * Probe every known codec/profile and return a structured report.
 * Used in startup diagnostics — runs in the background, never on the
 * critical path.
 */
export async function getWebCodecsCapabilityReport() {
    if (!isWebCodecsSupported()) {
        return {supported: false, codecs: {}};
    }

    const codecs = {};
    for (const [codecName, profiles] of Object.entries(WEBCODECS_CONFIGS)) {
        codecs[codecName] = {};
        for (const [profileName, codecString] of Object.entries(profiles)) {
            codecs[codecName][profileName] = await checkHardwareSupport(codecString);
        }
    }

    return {
        supported: true,
        codecs,
        features: {
            videoDecoder: typeof VideoDecoder !== "undefined",
            videoEncoder: typeof VideoEncoder !== "undefined",
            videoFrame: typeof VideoFrame !== "undefined",
            encodedVideoChunk: typeof EncodedVideoChunk !== "undefined",
        },
    };
}
