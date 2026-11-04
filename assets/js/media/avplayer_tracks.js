import { avplayerLogger as log } from "../core/logger.js";
import { hasPlayableSubtitleTimeBase } from "../player/subtitle_policy.js";

// FFmpeg's AVDisposition bit, which libmedia keeps on each stream.
const AV_DISPOSITION_FORCED = 0x40;

// libmedia's AVFormat values for Matroska and WebM.
const MATROSKA_FORMATS = new Set([8, 9]);

function hasDisposition(stream, flag) {
  return (Number(stream?.disposition) & flag) === flag;
}

// The codec parameters proxy reads WASM memory; a stream without readable
// parameters simply reports no channel count.
function streamChannels(stream) {
  try {
    const codecpar = stream?.codecparProxy;
    return Number(codecpar?.chLayout?.nbChannels || codecpar?.channels) || 0;
  } catch (_error) {
    return 0;
  }
}

/** Track normalization against the wrapper public-stream and legacy boundaries. */
export const avPlayerTracks = {
  _defaultTrackLanguage() {
    try {
      const format = this.player?.getFormatContext?.()?.format;
      const url = String(this.currentUrl || "");
      return MATROSKA_FORMATS.has(format) || /\.(mkv|webm)(\?|$)/i.test(url) ? "eng" : "";
    } catch (_error) {
      return "";
    }
  },
  async getAudioTracks() {
    if (!this.player) return [];

    try {
      // Method 1: Try AVPlayer's getAudioList (for HLS/DASH)
      if (typeof this.player.getAudioList === "function") {
        const result = await this.player.getAudioList();
        if (result?.list && result.list.length > 0) {
          return result.list.map((track, index) => ({
            id: track.id ?? index,
            index,
            label: track.name || track.title || `Audio ${index + 1}`,
            language: track.lang || track.language || "",
            selected: index === result.selectedIndex,
          }));
        }
      }

      // Method 2: AVPlayer's public stream API tells audio apart by media
      // type. The bitrate guess below also took subtitle streams (they carry
      // a low BPS too) for audio, listing a dozen fake audio tracks.
      if (typeof this.player.getStreams === "function") {
        const selectedId = this.player.getSelectedAudioStreamId?.() ?? -1;
        const defaultLanguage = this._defaultTrackLanguage();
        const audioStreams =
          this.player.getStreams()?.filter((stream) => stream.mediaType === "Audio") || [];

        if (audioStreams.length > 0) {
          return audioStreams.map((stream, index) => {
            const metadata = stream.metadata || {};

            return {
              id: stream.id,
              index,
              streamIndex: stream.index,
              label: metadata.title || `Audio ${index + 1}`,
              language: metadata.language || defaultLanguage,
              channels: streamChannels(stream),
              selected: stream.id === selectedId,
            };
          });
        }
      }

      // Method 3: Legacy guess for versions without the public stream API.
      // codecpar is a pointer in libmedia, so we use metadata to identify tracks
      const formatContext = this.player.getFormatContext?.();
      const selectedAudio = this.player.selectedAudioStream;
      const selectedVideo = this.player.selectedVideoStream;

      if (formatContext?.streams) {
        const audioTracks = [];
        const videoStreamIds = new Set();

        // First, identify video streams by selectedVideoStream
        if (selectedVideo) {
          videoStreamIds.add(selectedVideo.id);
        }

        // Identify audio streams - those that aren't video and have audio-like metadata
        formatContext.streams.forEach((stream) => {
          // Skip if it's the selected video stream
          if (videoStreamIds.has(stream.id)) return;

          // Check if this could be an audio stream based on metadata
          const metadata = stream.metadata || {};
          const title = metadata.title || "";
          const bps = parseInt(metadata.BPS, 10) || 0;

          // Audio streams typically have lower BPS than video (< 1Mbps usually)
          // Video streams typically have BPS > 1Mbps
          const isLikelyAudio = bps > 0 && bps < 1500000;

          // Also check if it's the selected audio stream
          const isSelectedAudio = selectedAudio && selectedAudio.id === stream.id;

          if (isSelectedAudio || isLikelyAudio) {
            audioTracks.push({
              id: stream.id,
              index: audioTracks.length,
              streamIndex: stream.index,
              label: title || `Audio ${audioTracks.length + 1}`,
              language: metadata.language || "",
              selected: isSelectedAudio,
            });
          }
        });

        // If we found no tracks but hasAudio is true, add the selected stream
        if (audioTracks.length === 0 && this.player.hasAudio?.() && selectedAudio) {
          const metadata = selectedAudio.metadata || {};
          audioTracks.push({
            id: selectedAudio.id,
            index: 0,
            streamIndex: selectedAudio.index,
            label: metadata.title || "Audio 1",
            language: metadata.language || "",
            selected: true,
          });
        }

        return audioTracks;
      }
    } catch (e) {
      log.warn("Error getting audio tracks:", e);
    }

    return [];
  },
  async getSubtitleTracks() {
    if (!this.player) return [];

    try {
      // Method 1: Try AVPlayer's getSubtitleList (for HLS/DASH)
      if (typeof this.player.getSubtitleList === "function") {
        const result = await this.player.getSubtitleList();
        if (result?.list && result.list.length > 0) {
          return result.list.map((track, index) => ({
            id: track.id ?? index,
            index,
            label: track.name || track.title || `Subtitle ${index + 1}`,
            language: track.lang || track.language || "",
            selected: index === result.selectedIndex,
          }));
        }
      }

      // Method 2: AVPlayer's public stream API covers embedded and external
      // subtitles for MP4/MKV without reaching into private player state.
      if (typeof this.player.getStreams === "function") {
        // libmedia picks a default track when its renderer starts; it stays
        // hidden (and unselected for the viewer) until one is chosen.
        const selectedId = this._subtitleChosen
          ? (this.player.getSelectedSubtitleStreamId?.() ?? -1)
          : -1;
        const defaultLanguage = this._defaultTrackLanguage();
        const streams = this.player.getStreams();
        const subtitleStreams =
          streams?.filter(
            (stream) => stream.mediaType === "Subtitle" && hasPlayableSubtitleTimeBase(stream),
          ) || [];

        if (subtitleStreams.length > 0) {
          return subtitleStreams.map((stream, index) => {
            const metadata = stream.metadata || {};

            return {
              id: stream.id,
              index,
              streamIndex: stream.index,
              label:
                metadata.title ||
                metadata.languageString ||
                metadata.name ||
                `Subtitle ${index + 1}`,
              language: metadata.language || defaultLanguage,
              forced: hasDisposition(stream, AV_DISPOSITION_FORCED),
              selected: stream.id === selectedId,
            };
          });
        }
      }

      // Method 3: Legacy guess for versions without the public stream API.
      const formatContext = this.player.getFormatContext?.();
      const selectedSub = this.player.selectedSubtitleStream;
      const selectedVideo = this.player.selectedVideoStream;
      const selectedAudio = this.player.selectedAudioStream;

      if (formatContext?.streams) {
        const subtitleTracks = [];
        const usedStreamIds = new Set();

        // Mark video and audio streams as used
        if (selectedVideo) usedStreamIds.add(selectedVideo.id);
        if (selectedAudio) usedStreamIds.add(selectedAudio.id);

        // Remaining streams that aren't video/audio could be subtitles
        formatContext.streams.forEach((stream) => {
          // Skip video and audio streams
          if (usedStreamIds.has(stream.id)) return;

          const metadata = stream.metadata || {};
          const bps = parseInt(metadata.BPS, 10) || 0;

          // Subtitle streams typically have very low or zero BPS
          // They're text-based so they're much smaller than audio
          const isLikelySubtitle = bps === 0 || bps < 50000;
          const isSelectedSub = selectedSub && selectedSub.id === stream.id;

          if ((isSelectedSub || isLikelySubtitle) && hasPlayableSubtitleTimeBase(stream)) {
            subtitleTracks.push({
              id: stream.id,
              index: subtitleTracks.length,
              streamIndex: stream.index,
              label: metadata.title || `Subtitle ${subtitleTracks.length + 1}`,
              language: metadata.language || "",
              selected: isSelectedSub,
            });
          }
        });

        // If hasSubtitle but we found nothing, add selected subtitle
        if (subtitleTracks.length === 0 && this.player.hasSubtitle?.() && selectedSub) {
          const metadata = selectedSub.metadata || {};
          subtitleTracks.push({
            id: selectedSub.id,
            index: 0,
            streamIndex: selectedSub.index,
            label: metadata.title || "Subtitle 1",
            language: metadata.language || "",
            selected: true,
          });
        }

        return subtitleTracks;
      }
    } catch (e) {
      log.warn("Error getting subtitle tracks:", e);
    }

    return [];
  },
};
