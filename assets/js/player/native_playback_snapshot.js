export function buildNativePlaybackSnapshot(video) {
  if (!video) return {};

  const bufferedRanges = [];
  for (let index = 0; index < video.buffered.length; index += 1) {
    bufferedRanges.push(
      `${video.buffered.start(index).toFixed(2)}-${video.buffered.end(index).toFixed(2)}`,
    );
  }

  return {
    current_time: Number.isFinite(video.currentTime) ? Number(video.currentTime.toFixed(3)) : 0,
    duration: Number.isFinite(video.duration) ? Number(video.duration.toFixed(3)) : 0,
    ready_state: video.readyState,
    network_state: video.networkState,
    paused: video.paused,
    seeking: video.seeking,
    autoplay: video.autoplay,
    preload: video.preload || video.getAttribute("preload"),
    buffered_range_count: bufferedRanges.length,
    buffered_ranges: bufferedRanges.join(","),
    has_current_src: !!video.currentSrc,
  };
}
