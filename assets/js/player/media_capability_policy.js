const DEFAULT_VIDEO_CODEC = "avc1.640028";
const DEFAULT_AUDIO_CODEC = "mp4a.40.2";

function finitePositive(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : fallback;
}

function normalizeCodec(value, fallback) {
  return typeof value === "string" && value.trim() ? value.trim() : fallback;
}

function contentTypeFor({ container, videoCodec, audioCodec }) {
  const type = container === "webm" ? "video/webm" : "video/mp4";
  const codecs = [videoCodec, audioCodec].filter(Boolean).join(",");
  return `${type}; codecs="${codecs}"`;
}

export function buildMediaDecodingConfiguration({
  container = "mp4",
  videoCodec = DEFAULT_VIDEO_CODEC,
  audioCodec = DEFAULT_AUDIO_CODEC,
  width = 1920,
  height = 1080,
  bitrate = 8_000_000,
  framerate = 30,
  audioBitrate = 192_000,
  sampleRate = 48_000,
  channels = 2,
} = {}) {
  const normalizedVideoCodec = normalizeCodec(videoCodec, DEFAULT_VIDEO_CODEC);
  const normalizedAudioCodec = normalizeCodec(audioCodec, DEFAULT_AUDIO_CODEC);

  return Object.freeze({
    type: "media-source",
    video: Object.freeze({
      contentType: contentTypeFor({
        container,
        videoCodec: normalizedVideoCodec,
        audioCodec: normalizedAudioCodec,
      }),
      width: Math.round(finitePositive(width, 1920)),
      height: Math.round(finitePositive(height, 1080)),
      bitrate: Math.round(finitePositive(bitrate, 8_000_000)),
      framerate: finitePositive(framerate, 30),
    }),
    audio: Object.freeze({
      contentType: `audio/mp4; codecs="${normalizedAudioCodec}"`,
      channels: String(Math.round(finitePositive(channels, 2))),
      bitrate: Math.round(finitePositive(audioBitrate, 192_000)),
      samplerate: Math.round(finitePositive(sampleRate, 48_000)),
    }),
  });
}

export function summarizeMediaCapability(result, configuration = null) {
  const supported = result?.supported === true;
  const smooth = result?.smooth === true;
  const powerEfficient = result?.powerEfficient === true;

  return Object.freeze({
    available: result != null,
    supported,
    smooth,
    powerEfficient,
    preferNative: supported && smooth && powerEfficient,
    avoidNative: result != null && (!supported || !smooth),
    avoidHighResolution: result != null && (!smooth || !powerEfficient),
    configuration,
  });
}

export async function probeMediaCapability({
  configuration = buildMediaDecodingConfiguration(),
  decodingInfo = globalThis.navigator?.mediaCapabilities?.decodingInfo?.bind(
    globalThis.navigator.mediaCapabilities,
  ),
  timeoutMs = 250,
} = {}) {
  if (typeof decodingInfo !== "function") {
    return summarizeMediaCapability(null, configuration);
  }

  try {
    const probe = Promise.resolve(decodingInfo(configuration));
    const timeout = Number(timeoutMs);
    const result =
      Number.isFinite(timeout) && timeout > 0
        ? await Promise.race([
            probe,
            new Promise((resolve) => setTimeout(() => resolve(null), timeout)),
          ])
        : await probe;
    return summarizeMediaCapability(result, configuration);
  } catch {
    return summarizeMediaCapability(null, configuration);
  }
}

export function configurationFromPlayerElement(element, streamType = "mp4") {
  const dataset = element?.dataset ?? {};
  const container =
    dataset.container || (String(streamType).toLowerCase().includes("webm") ? "webm" : "mp4");

  return buildMediaDecodingConfiguration({
    container,
    videoCodec: dataset.videoCodec || dataset.codec || DEFAULT_VIDEO_CODEC,
    audioCodec: dataset.audioCodec || DEFAULT_AUDIO_CODEC,
    width: dataset.videoWidth || dataset.width,
    height: dataset.videoHeight || dataset.height,
    bitrate: dataset.videoBitrate || dataset.bitrate,
    framerate: dataset.framerate || dataset.frameRate,
    audioBitrate: dataset.audioBitrate,
    sampleRate: dataset.audioSampleRate,
    channels: dataset.audioChannels,
  });
}

export async function probePlayerMediaCapability(element, streamType, options = {}) {
  return probeMediaCapability({
    ...options,
    configuration: configurationFromPlayerElement(element, streamType),
  });
}
