import { ContentType, selectStreamingMode } from "../media/streaming_config.js";
import { parseNextEpisode } from "./next_episode.js";
import { isIosPwaMode, readEngineFlag } from "./playback_environment.js";
import { PlaybackSession } from "./playback_session.js";

const FALLBACK_COOLDOWNS = [2_000, 5_000, 10_000, 20_000, 30_000];

const defaultDependencies = {
  createPlaybackMetrics: () => new PlaybackSession(),
  isIosPwaMode,
  now: () => Date.now(),
  parseNextEpisode,
  readEngineFlag,
  selectStreamingMode,
};

const finiteNumber = (value, fallback = 0) => {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
};

export function createInitialPlayerState(
  el,
  { dependencies = {}, documentRef = globalThis.document } = {},
) {
  const deps = { ...defaultDependencies, ...dependencies };
  const dataset = el?.dataset || {};
  const contentType = dataset.contentType || "live";
  const initialMode = dataset.streamingMode || null;
  const serializedNextEpisode = dataset.nextEpisode;
  const nextEpisode = deps.parseNextEpisode(serializedNextEpisode);

  return {
    streamUrl: dataset.streamUrl,
    proxyUrl: dataset.proxyUrl,
    contentType,
    sourceType: dataset.sourceType || null,
    contentId: dataset.contentId,
    imdbId: dataset.imdbId || null,
    subtitlesEnabled: dataset.subtitlesEnabled !== "false",
    subtitleLang: dataset.subtitleLang || "pt-BR",
    subtitleOffsetMs: finiteNumber(dataset.subtitleOffsetMs),
    mediaTitle: dataset.mediaTitle || documentRef?.title || "Streamix",
    mediaSubtitle: dataset.mediaSubtitle || "Streamix",
    initialMode,
    expectedDuration: Number.parseInt(dataset.expectedDuration, 10) || 0,
    playerLifecycleLogs: dataset.playerLifecycleLogs === "true",

    streamLoader: null,
    hls: null,
    mpegtsPlayer: null,
    streamingMode:
      initialMode ||
      deps.selectStreamingMode(contentType === "live" ? ContentType.LIVE : ContentType.VOD, "good"),
    currentStreamType: null,
    currentUrl: null,

    manualQuality: null,
    availableQualities: [],

    audioTracks: [],
    subtitleTracks: [],
    _nativeExternalSubtitleTrack: null,
    _nativeExternalSubtitleReloading: false,
    _subtitleOffsetReloadTimer: null,
    _externalSubtitleBlobUrl: null,
    _externalSubtitleLoadedFor: null,
    selectedAudioTrack: 0,
    selectedSubtitleTrack: -1,

    retryCount: 0,
    maxRetries: 3,
    useProxy: true,
    fallbackAttempts: 0,
    maxFallbackAttempts: 5,
    lastFallbackTime: 0,
    fallbackCooldowns: [...FALLBACK_COOLDOWNS],

    startTime: deps.now(),
    lastProgressReport: 0,
    playbackSessionId: 0,
    playbackMetrics: deps.createPlaybackMetrics(),

    pipActive: false,
    networkMonitor: null,
    keyboardManager: null,
    aspectRatioController: null,
    mobileControls: null,

    avPlayer: null,
    usingAVPlayer: false,
    audioCheckTimeout: null,
    avPlayerAttempted: false,
    avPlayerTimeInterval: null,
    preferAVPlayer: false,

    avbridge: null,
    usingAvbridge: false,
    avbridgeAttempted: false,
    featureFlagAvbridge: deps.readEngineFlag(el, "avbridge"),

    h265web: null,
    usingH265web: false,
    h265webAttempted: false,
    h265webTimeInterval: null,
    featureFlagH265web: deps.readEngineFlag(el, "h265web"),

    nextEpisode,
    nextEpisodeParseFailed: Boolean(serializedNextEpisode && !nextEpisode),
    nextEpisodeController: null,

    codecABR: null,
    advancedCapabilities: null,
    preferredCodec: null,

    nativeBufferManager: null,
    nativeBufferingController: null,
    nativeTouchControls: false,
    _emergencyStopDone: false,
    iosPwaMode: deps.isIosPwaMode(),
    _suspendingForIos: false,
    _wasPlayingBeforeHidden: false,
    _lastIosPwaTapAt: 0,
    _destroyed: false,
  };
}
