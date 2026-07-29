function codecText(quality) {
  return [quality?.videoCodec, quality?.codecs]
    .filter((value) => typeof value === "string")
    .join(",");
}

export function detectQualityCodec(quality) {
  const codecs = codecText(quality).toLowerCase();
  if (codecs.includes("av01") || codecs.includes("av1")) return "av1";
  if (codecs.includes("hvc1") || codecs.includes("hev1") || codecs.includes("hevc")) {
    return "hevc";
  }
  if (codecs.includes("vp09") || codecs.includes("vp9")) return "vp9";
  if (codecs.includes("avc1") || codecs.includes("h264")) return "h264";
  return "unknown";
}

export function qualityVideoCodec(quality) {
  const codec = codecText(quality)
    .split(",")
    .map((value) => value.trim().replaceAll('"', ""))
    .find((value) => /^(avc1|hvc1|hev1|av01|vp09|vp9)/i.test(value));

  return codec || null;
}

export function buildQualityMediaConfig(quality) {
  const codec = qualityVideoCodec(quality);
  if (!codec || !quality?.width || !quality?.height || !quality?.bitrate) return null;

  const isWebmCodec = /^(vp9|vp09)/i.test(codec);

  return {
    type: "media-source",
    video: {
      contentType: `${isWebmCodec ? "video/webm" : "video/mp4"}; codecs="${codec}"`,
      width: quality.width,
      height: quality.height,
      bitrate: quality.bitrate,
      framerate: Number(quality.frameRate) || 30,
    },
  };
}

export function buildQualityProbeCandidates(qualities, limit = 8) {
  return qualities
    .map((quality) => ({ quality, config: buildQualityMediaConfig(quality) }))
    .filter(({ config }) => config)
    .slice(0, limit);
}
