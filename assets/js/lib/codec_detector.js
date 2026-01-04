/**
 * Codec Capability Detector
 *
 * Detects browser support for various video and audio codecs.
 * Inspired by Netflix's codec detection strategy for optimal stream selection.
 *
 * Key features:
 * - Detects AV1, HEVC, VP9, H.264 video codec support
 * - Detects AC3, EAC3, DTS, AAC, Opus audio codec support
 * - Checks hardware acceleration availability
 * - Provides capability report for backend stream selection
 */

// Codec test configurations
const VIDEO_CODECS = {
  av1: [
    'video/mp4; codecs="av01.0.01M.08"', // AV1 Main Profile, Level 2.1
    'video/mp4; codecs="av01.0.05M.08"', // AV1 Main Profile, Level 3.1
    'video/webm; codecs="av01.0.01M.08"',
  ],
  hevc: [
    'video/mp4; codecs="hvc1.1.6.L93.B0"', // HEVC Main Profile
    'video/mp4; codecs="hev1.1.6.L93.B0"',
    'video/mp4; codecs="hvc1"',
    'video/mp4; codecs="hevc"',
  ],
  vp9: [
    'video/webm; codecs="vp9"',
    'video/webm; codecs="vp09.00.10.08"',
    'video/mp4; codecs="vp09.00.10.08"',
  ],
  h264: [
    'video/mp4; codecs="avc1.42E01E"', // H.264 Baseline
    'video/mp4; codecs="avc1.4D401E"', // H.264 Main
    'video/mp4; codecs="avc1.64001E"', // H.264 High
  ],
  vp8: ['video/webm; codecs="vp8"'],
};

const AUDIO_CODECS = {
  aac: ['audio/mp4; codecs="mp4a.40.2"', "audio/aac"],
  ac3: ['audio/mp4; codecs="ac-3"', "audio/ac3"],
  eac3: ['audio/mp4; codecs="ec-3"', "audio/eac3"],
  dts: ["audio/dts", 'audio/mp4; codecs="dts"'],
  opus: ["audio/opus", 'audio/webm; codecs="opus"'],
  flac: ["audio/flac", 'audio/ogg; codecs="flac"'],
  mp3: ["audio/mpeg", "audio/mp3"],
  vorbis: ['audio/ogg; codecs="vorbis"', "audio/vorbis"],
};

// HDR support detection
const HDR_FORMATS = {
  hdr10: ['video/mp4; codecs="hvc1.2.4.L153.B0"', 'video/webm; codecs="vp09.02.10.10"'],
  dolbyVision: ['video/mp4; codecs="dvh1.05.06"', 'video/mp4; codecs="dvhe.05.06"'],
  hlg: ['video/mp4; codecs="hvc1.2.4.L153.B0"; transfer=hlg'],
};

/**
 * Test if a specific MIME type is supported
 */
function testMimeType(mimeType) {
  const video = document.createElement("video");
  const result = video.canPlayType(mimeType);
  return result === "probably" || result === "maybe";
}

/**
 * Test codec support with multiple MIME type variants
 */
function testCodec(mimeTypes) {
  for (const mime of mimeTypes) {
    if (testMimeType(mime)) {
      return { supported: true, mime };
    }
  }
  return { supported: false, mime: null };
}

/**
 * Detect all video codec capabilities
 */
export function detectVideoCodecs() {
  const results = {};

  for (const [codec, mimeTypes] of Object.entries(VIDEO_CODECS)) {
    const test = testCodec(mimeTypes);
    results[codec] = {
      supported: test.supported,
      mime: test.mime,
    };
  }

  return results;
}

/**
 * Detect all audio codec capabilities
 */
export function detectAudioCodecs() {
  const results = {};

  for (const [codec, mimeTypes] of Object.entries(AUDIO_CODECS)) {
    const test = testCodec(mimeTypes);
    results[codec] = {
      supported: test.supported,
      mime: test.mime,
    };
  }

  return results;
}

/**
 * Detect HDR format support
 */
export function detectHDRSupport() {
  const results = {};

  for (const [format, mimeTypes] of Object.entries(HDR_FORMATS)) {
    const test = testCodec(mimeTypes);
    results[format] = test.supported;
  }

  // Also check for HDR display capability via CSS
  const supportsHDRDisplay = window.matchMedia?.("(dynamic-range: high)").matches;

  return {
    ...results,
    display: supportsHDRDisplay,
  };
}

/**
 * Check MediaSource Extensions support
 */
export function detectMSESupport() {
  const supported = "MediaSource" in window;
  let codecs = [];

  if (supported && window.MediaSource) {
    // Test which codecs MSE supports
    const testCodecs = [
      'video/mp4; codecs="avc1.42E01E"',
      'video/mp4; codecs="hvc1.1.6.L93.B0"',
      'video/webm; codecs="vp9"',
      'video/mp4; codecs="av01.0.01M.08"',
    ];

    codecs = testCodecs.filter((c) => MediaSource.isTypeSupported(c));
  }

  return { supported, codecs };
}

/**
 * Check Encrypted Media Extensions (EME) / DRM support
 */
export async function detectDRMSupport() {
  const results = {
    supported: "requestMediaKeySystemAccess" in navigator,
    systems: {},
  };

  if (!results.supported) return results;

  const keySystems = [
    { name: "widevine", id: "com.widevine.alpha" },
    { name: "playready", id: "com.microsoft.playready" },
    { name: "fairplay", id: "com.apple.fps.1_0" },
    { name: "clearkey", id: "org.w3.clearkey" },
  ];

  const config = [
    {
      initDataTypes: ["cenc"],
      videoCapabilities: [{ contentType: 'video/mp4; codecs="avc1.42E01E"' }],
      audioCapabilities: [{ contentType: 'audio/mp4; codecs="mp4a.40.2"' }],
    },
  ];

  for (const system of keySystems) {
    try {
      await navigator.requestMediaKeySystemAccess(system.id, config);
      results.systems[system.name] = true;
    } catch {
      results.systems[system.name] = false;
    }
  }

  return results;
}

/**
 * Check hardware acceleration support
 */
export async function detectHardwareAcceleration() {
  const results = {
    webgl: false,
    webgl2: false,
    gpu: null,
    webgpu: false,
  };

  // Check WebGL
  const canvas = document.createElement("canvas");
  const gl = canvas.getContext("webgl");
  if (gl) {
    results.webgl = true;
    const debugInfo = gl.getExtension("WEBGL_debug_renderer_info");
    if (debugInfo) {
      results.gpu = gl.getParameter(debugInfo.UNMASKED_RENDERER_WEBGL);
    }
  }

  // Check WebGL2
  const gl2 = canvas.getContext("webgl2");
  results.webgl2 = !!gl2;

  // Check WebGPU
  if ("gpu" in navigator) {
    try {
      const adapter = await navigator.gpu?.requestAdapter();
      results.webgpu = !!adapter;
    } catch {
      results.webgpu = false;
    }
  }

  return results;
}

/**
 * Get full codec capability report
 * This can be sent to the backend for optimal stream selection
 */
export async function getCodecCapabilityReport() {
  const [hardware, drm] = await Promise.all([detectHardwareAcceleration(), detectDRMSupport()]);

  return {
    video: detectVideoCodecs(),
    audio: detectAudioCodecs(),
    hdr: detectHDRSupport(),
    mse: detectMSESupport(),
    drm,
    hardware,
    browser: {
      userAgent: navigator.userAgent,
      platform: navigator.platform,
      vendor: navigator.vendor,
    },
    timestamp: Date.now(),
  };
}

/**
 * Get simplified capability summary for quick decisions
 * Returns the best codecs supported by this device
 */
export function getCapabilitySummary() {
  const video = detectVideoCodecs();
  const audio = detectAudioCodecs();

  // Determine best video codec (preference order: AV1 > HEVC > VP9 > H264)
  let bestVideoCodec = "h264";
  if (video.av1.supported) bestVideoCodec = "av1";
  else if (video.hevc.supported) bestVideoCodec = "hevc";
  else if (video.vp9.supported) bestVideoCodec = "vp9";

  // Check for advanced audio support
  const needsAudioFallback = !audio.ac3.supported || !audio.eac3.supported || !audio.dts.supported;

  return {
    bestVideoCodec,
    supportsAV1: video.av1.supported,
    supportsHEVC: video.hevc.supported,
    supportsVP9: video.vp9.supported,
    needsAudioFallback,
    supportsOpus: audio.opus.supported,
    supportsAAC: audio.aac.supported,
  };
}

/**
 * Check if browser can play a specific stream configuration
 * Useful for pre-flight checks before attempting playback
 */
export function canPlayStream(videoCodec, audioCodec) {
  const video = detectVideoCodecs();
  const audio = detectAudioCodecs();

  const videoSupported = !videoCodec || video[videoCodec]?.supported;
  const audioSupported = !audioCodec || audio[audioCodec]?.supported;

  return {
    canPlay: videoSupported && audioSupported,
    videoSupported,
    audioSupported,
    needsFallback: !audioSupported,
  };
}

export default {
  detectVideoCodecs,
  detectAudioCodecs,
  detectHDRSupport,
  detectMSESupport,
  detectDRMSupport,
  detectHardwareAcceleration,
  getCodecCapabilityReport,
  getCapabilitySummary,
  canPlayStream,
};
