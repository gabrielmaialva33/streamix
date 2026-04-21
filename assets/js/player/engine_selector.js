// Pure engine-selection decision for the video player hook.
//
// This module contains NO side effects and NO references to `window`,
// `navigator`, or any DOM. All dynamic capabilities / device state must
// be passed in via `ctx` by the caller. That makes the decision easy to
// unit-test and keeps `video_player.js` focused on lifecycle + wiring.
//
// Return values mirror the verbs the caller already uses:
//   "avplayer"     -> call this.tryAVPlayerFallback()
//   "native"       -> call this.playNative()
//   "hls-js"       -> call this.playWithHls()
//   "mpegts"       -> call this.playWithMpegts()   (TS/xtream path)
//   "mpegts-flv"   -> call this.playWithMpegts("flv")
//   "flv-unsupported" -> show the FLV-not-supported error
//
// Extracted from `assets/js/hooks/video_player.js` initPlayer() branch
// (previously lines ~1345-1404). Behavior is preserved exactly.

/**
 * @typedef {Object} EngineSelectorCtx
 * @property {string}  streamType              - e.g. "hls" | "ts" | "xtream" | "flv" | "mp4" | "mkv" | ...
 * @property {string}  [sourceType]            - e.g. "gindex" | "xtream" | ...
 * @property {string}  [recommendedPlayer]     - from Device Codec Memory: "avplayer" | "native" | ...
 * @property {boolean} [preferAVPlayer]        - user preference flag
 * @property {boolean} [avPlayerAttempted]     - true if AVPlayer fallback was already tried
 * @property {boolean} [shouldPreferAVPlayerForLiveTs] - precomputed by caller (depends on UA + contentType + streamType)
 * @property {Object}  [capabilities]          - runtime capability probes, passed in by caller
 * @property {boolean} [capabilities.hlsJs]    - isHlsJsSupported()
 * @property {boolean} [capabilities.mpegts]   - isMpegtsSupported()
 */

/**
 * Decide which engine the video player should use for the given context.
 *
 * @param {EngineSelectorCtx} ctx
 * @returns {"avplayer"|"native"|"hls-js"|"mpegts"|"mpegts-flv"|"flv-unsupported"}
 */
export function selectEngine(ctx) {
    const {
        streamType,
        sourceType,
        recommendedPlayer,
        preferAVPlayer,
        avPlayerAttempted,
        shouldPreferAVPlayerForLiveTs,
        capabilities = {},
    } = ctx;

    const hlsJs = !!capabilities.hlsJs;
    const mpegts = !!capabilities.mpegts;

    // Device Codec Memory recommendation (Netflix pattern).
    if (recommendedPlayer === "avplayer" && !avPlayerAttempted) {
        return "avplayer";
    }

    // Manual AVPlayer preference for GIndex / MKV.
    if (preferAVPlayer && (sourceType === "gindex" || streamType === "mkv")) {
        return "avplayer";
    }

    // GIndex uses native playback.
    if (sourceType === "gindex") {
        return "native";
    }

    switch (streamType) {
        case "hls":
            return "hls-js";

        case "ts":
        case "xtream":
            if (shouldPreferAVPlayerForLiveTs) {
                return "avplayer";
            }
            if (mpegts) return "mpegts";
            if (hlsJs) return "hls-js";
            return "native";

        case "flv":
            return mpegts ? "mpegts-flv" : "flv-unsupported";

        case "mp4":
        case "mkv":
            return "native";

        default:
            if (hlsJs) return "hls-js";
            if (mpegts) return "mpegts";
            return "native";
    }
}
