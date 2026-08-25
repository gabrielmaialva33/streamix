import { ENGINE_SELECTION } from "./engine_contract.js";

// Pure engine-selection decision for the video player hook.
//
// This module contains NO side effects and NO references to `window`,
// `navigator`, or any DOM. All dynamic capabilities / device state must
// be passed in via `ctx` by the caller. That makes the decision easy to
// unit-test and keeps `video_player.js` focused on lifecycle + wiring.
//
// Return values mirror the verbs the caller already uses:
//   "avbridge"    -> call this.playWithAvbridge()       (preferred GPU HEVC, GIndex MKV/HEVC)
//   "h265web"     -> call this.playWithH265web()        (alt GPU HEVC; needs SAB + COOP+COEP)
//   "avplayer"     -> call this.tryAVPlayerFallback()
//   "native"       -> call this.playNative()
//   "hls-js"       -> call this.playWithHls()
//   "mpegts"       -> call this.playWithMpegts()   (TS/xtream path)
//   "mpegts-flv"   -> call this.playWithMpegts("flv")
//   "flv-unsupported" -> show the FLV-not-supported error
//
// Extracted from `assets/js/hooks/video_player.js` so browser policy and
// fallback ordering remain explicit and independently testable.

/**
 * @typedef {Object} EngineSelectorCtx
 * @property {string}  streamType              - e.g. "hls" | "ts" | "xtream" | "flv" | "mp4" | "mkv" | ...
 * @property {string}  [sourceType]            - e.g. "gindex" | "xtream" | ...
 * @property {string}  [recommendedPlayer]     - from Device Codec Memory: "avplayer" | "native" | ...
 * @property {boolean} [preferAVPlayer]        - user preference flag
 * @property {boolean} [avPlayerAttempted]     - true if AVPlayer fallback was already tried
 * @property {boolean} [shouldPreferAVPlayerForLiveTs] - precomputed by caller (depends on UA + contentType + streamType)
 * @property {boolean} [preferNativeHls]       - explicit Apple/WebKit native-HLS preference
 * @property {boolean} [isUhdHevc]             - server-side hint: this is a 2160p/HEVC release
 * @property {boolean} [avbridgeAttempted]   - true if avbridge was already tried for this content
 * @property {boolean} [h265webAttempted]    - true if h265web was already tried for this content
 * @property {Object}  [capabilities]          - runtime capability probes, passed in by caller
 * @property {boolean} [capabilities.hlsJs]    - isHlsJsSupported()
 * @property {boolean} [capabilities.mpegts]   - isMpegtsSupported()
 * @property {boolean} [capabilities.nativeHls] - <video>.canPlayType("application/vnd.apple.mpegurl") || "application/x-mpegURL"
 * @property {boolean} [capabilities.avbridge] - true when avbridge engine is enabled + WebCodecs HEVC available
 * @property {boolean} [capabilities.h265web]  - true when h265web engine is enabled + WebCodecs HEVC available
 */

/**
 * Decide which engine the video player should use for the given context.
 *
 * @param {EngineSelectorCtx} ctx
 * @returns {"avbridge"|"h265web"|"avplayer"|"native"|"hls-js"|"mpegts"|"mpegts-flv"|"flv-unsupported"}
 */
export function selectEngine(ctx) {
  const {
    streamType,
    sourceType,
    recommendedPlayer,
    preferAVPlayer,
    avPlayerAttempted,
    avbridgeAttempted,
    h265webAttempted,
    isUhdHevc,
    shouldPreferAVPlayerForLiveTs,
    preferNativeHls,
    capabilities = {},
    mediaCapability = null,
  } = ctx;
  const avoidNative = mediaCapability?.avoidNative === true;
  const preferNativeByCapability = mediaCapability?.preferNative === true;

  const hlsJs = !!capabilities.hlsJs;
  const mpegts = !!capabilities.mpegts;
  const avbridge = !!capabilities.avbridge;
  const canTryAvbridge = avbridge && !avbridgeAttempted;
  const h265web = !!capabilities.h265web;
  const canTryH265web = h265web && !h265webAttempted;
  const nativeHls = !!capabilities.nativeHls;
  const canTryAVPlayer = !avPlayerAttempted;

  // HLS has a browser-policy decision before any remembered fallback.
  // A stale AVPlayer recommendation must not bypass native HLS on Apple
  // or MSE/hls.js everywhere else.
  if (streamType === "hls" || streamType === "m3u8") {
    if ((preferNativeHls || preferNativeByCapability) && nativeHls && !avoidNative) {
      return ENGINE_SELECTION.NATIVE;
    }
    if (hlsJs) return ENGINE_SELECTION.HLS_JS;
    return ENGINE_SELECTION.NATIVE;
  }

  // Raw transport streams are not HLS manifests. Keep this branch ahead
  // of remembered player preferences so a stale AVPlayer recommendation
  // cannot bypass mpegts.js, and never feed Xtream TS bytes to hls.js.
  if (streamType === "ts" || streamType === "xtream") {
    if (mpegts) return ENGINE_SELECTION.MPEGTS;
    if (canTryAVPlayer && shouldPreferAVPlayerForLiveTs) return ENGINE_SELECTION.AVPLAYER;
    return ENGINE_SELECTION.NATIVE;
  }

  // 4K HEVC content (2160p, HEVC/x265, "UHD") is the only place the
  // libmedia WASM software path actually struggles in field telemetry —
  // CPU pegs at 60-90% during decode and seeks stutter, and at 10-bit
  // Main 10 HDR10 it refuses to demux with `open stream failed ret:-2`.
  // The GPU paths are gated on the server-side `is_4k_hevc` hint plus
  // an MP4/MKV container guard (HLS / TS / FLV / live still belongs on
  // AVPlayer or mpegts.js). Previously we also required
  // `sourceType === "gindex"` but caught a 4K HDR10 MP4 served by the
  // Xtream provider falling through to AVPlayer → fatal, so we now
  // accept any VOD-style container with the UHD hint.
  const isVodContainer = streamType === "mkv" || streamType === "mp4";

  if (canTryAvbridge && isUhdHevc && isVodContainer) {
    return ENGINE_SELECTION.AVBRIDGE;
  }

  // Same target content but for the h265web engine — kept around for
  // environments that already pay the COOP+COEP cost (so they get
  // SharedArrayBuffer + multi-threaded HEVC decode). Off by default;
  // flip the `feature_h265web` Application config when you wire the
  // headers. Same `isUhdHevc` + container guard so non-4K stays on
  // AVPlayer.
  if (canTryH265web && isUhdHevc && isVodContainer) {
    return ENGINE_SELECTION.H265WEB;
  }

  // Device Codec Memory recommendation (Netflix pattern).
  if (canTryAVPlayer && recommendedPlayer === "avplayer") {
    return ENGINE_SELECTION.AVPLAYER;
  }

  // Manual AVPlayer preference for GIndex / MKV.
  if (canTryAVPlayer && preferAVPlayer && (sourceType === "gindex" || streamType === "mkv")) {
    return ENGINE_SELECTION.AVPLAYER;
  }

  // GIndex often serves Matroska/HEVC releases through signed download.aspx URLs.
  // Native <video> handles some MP4 variants well, but MKV needs AVPlayer's
  // demuxer/decoder path or the browser mistakes valid media for unsupported MP4.
  if (canTryAVPlayer && sourceType === "gindex" && streamType === "mkv") {
    return ENGINE_SELECTION.AVPLAYER;
  }

  // GIndex MP4 can use native playback.
  if (sourceType === "gindex") {
    if (avoidNative && canTryAVPlayer) return ENGINE_SELECTION.AVPLAYER;
    return ENGINE_SELECTION.NATIVE;
  }

  switch (streamType) {
    case "flv":
      return mpegts ? ENGINE_SELECTION.MPEGTS_FLV : ENGINE_SELECTION.FLV_UNSUPPORTED;

    case "mp4":
    case "mkv":
      if (avoidNative && canTryAVPlayer) return ENGINE_SELECTION.AVPLAYER;
      return ENGINE_SELECTION.NATIVE;

    default:
      // Mixed/unknown follows the same explicit Apple-native policy.
      if ((preferNativeHls || preferNativeByCapability) && nativeHls && !avoidNative) {
        return ENGINE_SELECTION.NATIVE;
      }
      if (hlsJs) return ENGINE_SELECTION.HLS_JS;
      if (nativeHls && !avoidNative) return ENGINE_SELECTION.NATIVE;
      if (mpegts) return ENGINE_SELECTION.MPEGTS;
      return ENGINE_SELECTION.NATIVE;
  }
}
