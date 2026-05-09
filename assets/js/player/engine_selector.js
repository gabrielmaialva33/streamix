// Pure engine-selection decision for the video player hook.
//
// This module contains NO side effects and NO references to `window`,
// `navigator`, or any DOM. All dynamic capabilities / device state must
// be passed in via `ctx` by the caller. That makes the decision easy to
// unit-test and keeps `video_player.js` focused on lifecycle + wiring.
//
// Return values mirror the verbs the caller already uses:
//   "h265web"     -> call this.playWithH265web()        (GPU HEVC, GIndex MKV/HEVC)
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
 * @property {boolean} [h265webAttempted]    - true if h265web was already tried for this content
 * @property {Object}  [capabilities]          - runtime capability probes, passed in by caller
 * @property {boolean} [capabilities.hlsJs]    - isHlsJsSupported()
 * @property {boolean} [capabilities.mpegts]   - isMpegtsSupported()
 * @property {boolean} [capabilities.nativeHls] - <video>.canPlayType("application/vnd.apple.mpegurl") || "application/x-mpegURL"
 * @property {boolean} [capabilities.h265web]  - true when h265web is available + the runtime can use WebCodecs for HEVC
 */

/**
 * Decide which engine the video player should use for the given context.
 *
 * @param {EngineSelectorCtx} ctx
 * @returns {"h265web"|"avplayer"|"native"|"hls-js"|"mpegts"|"mpegts-flv"|"flv-unsupported"}
 */
export function selectEngine(ctx) {
  const {
    streamType,
    sourceType,
    recommendedPlayer,
    preferAVPlayer,
    avPlayerAttempted,
    h265webAttempted,
    shouldPreferAVPlayerForLiveTs,
    capabilities = {},
  } = ctx;

  const hlsJs = !!capabilities.hlsJs;
  const mpegts = !!capabilities.mpegts;
  const h265web = !!capabilities.h265web;
  const canTryH265web = h265web && !h265webAttempted;
  // iOS Safari (and macOS Safari) implement HLS in the platform — feeding
  // the .m3u8 directly into <video> wins us hardware decode + AirPlay +
  // PiP integration that hls.js can't reach. The official hls.js README
  // shows the same native-first ordering. iOS returns false for
  // `Hls.isSupported()` anyway, so this is the only way to play HLS at
  // all on iPhone.
  const nativeHls = !!capabilities.nativeHls;
  const canTryAVPlayer = !avPlayerAttempted;

  // GIndex MKV / HEVC content via h265web — preferred when the runtime
  // exposes WebCodecs HEVC hardware decode. h265web demuxes MKV in JS
  // and feeds samples to WebCodecs, so the GPU does the heavy lifting
  // instead of the libmedia WASM software decoder. We only walk this
  // path when the caller has confirmed both that h265web can boot
  // *and* that the browser advertises a HEVC decoder. Anything else
  // falls through to AVPlayer (libmedia) on the next branch.
  if (canTryH265web && sourceType === "gindex" && streamType === "mkv") {
    return "h265web";
  }

  // Device Codec Memory recommendation (Netflix pattern).
  if (canTryAVPlayer && recommendedPlayer === "avplayer") {
    return "avplayer";
  }

  // Manual AVPlayer preference for GIndex / MKV.
  if (canTryAVPlayer && preferAVPlayer && (sourceType === "gindex" || streamType === "mkv")) {
    return "avplayer";
  }

  // GIndex often serves Matroska/HEVC releases through signed download.aspx URLs.
  // Native <video> handles some MP4 variants well, but MKV needs AVPlayer's
  // demuxer/decoder path or the browser mistakes valid media for unsupported MP4.
  if (canTryAVPlayer && sourceType === "gindex" && streamType === "mkv") {
    return "avplayer";
  }

  // GIndex MP4 can use native playback.
  if (sourceType === "gindex") {
    return "native";
  }

  switch (streamType) {
    case "hls":
      // Native HLS first (hls.js README pattern). Falls back to
      // hls.js on Chrome / Firefox / Edge / Android.
      if (nativeHls) return "native";
      if (hlsJs) return "hls-js";
      return "native";

    case "ts":
    case "xtream":
      if (canTryAVPlayer && shouldPreferAVPlayerForLiveTs) {
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
      // Mixed/unknown: still prefer native HLS when the URL ends up
      // being treated as HLS by Safari, then hls.js, then mpegts.
      if (nativeHls) return "native";
      if (hlsJs) return "hls-js";
      if (mpegts) return "mpegts";
      return "native";
  }
}
