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
    capabilities = {},
  } = ctx;

  const hlsJs = !!capabilities.hlsJs;
  const mpegts = !!capabilities.mpegts;
  const avbridge = !!capabilities.avbridge;
  const canTryAvbridge = avbridge && !avbridgeAttempted;
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

  // 4K HEVC content (2160p, HEVC/x265, "UHD") is the only place the
  // libmedia WASM software path actually struggles in field telemetry —
  // CPU pegs at 60-90% during decode and seeks stutter. Anything below
  // 4K plays just fine on AVPlayer, so we keep the GPU paths gated on
  // the server-side `is_4k_hevc` hint. That keeps the heavy bundle
  // (mediabunny, libavjs-webcodecs-bridge) off the critical path for
  // the 1080p/720p catalog.
  if (canTryAvbridge && sourceType === "gindex" && streamType === "mkv" && isUhdHevc) {
    return "avbridge";
  }

  // Same target content but for the h265web engine — kept around for
  // environments that already pay the COOP+COEP cost (so they get
  // SharedArrayBuffer + multi-threaded HEVC decode). Off by default;
  // flip the `feature_h265web` Application config when you wire the
  // headers. Same `isUhdHevc` gate so non-4K stays on AVPlayer.
  if (canTryH265web && sourceType === "gindex" && streamType === "mkv" && isUhdHevc) {
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
