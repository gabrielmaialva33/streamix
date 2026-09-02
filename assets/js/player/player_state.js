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
    partyMode: dataset.partyMode === "true",
    partyRole: dataset.partyRole || "none",
    sourceFailoverEnabled: dataset.sourceFailoverEnabled === "true",
    mediaTitle: dataset.mediaTitle || documentRef?.title || "Streamix",
    mediaSubtitle: dataset.mediaSubtitle || "Streamix",
    initialMode,
    expectedDuration: Number.parseInt(dataset.expectedDuration, 10) || 0,
    playerLifecycleLogs: dataset.playerLifecycleLogs === "true",

    streamLoader: null,
    mediaElementEngine: null,
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
    subtitleSourceResolver: null,
    nativeSubtitleController: null,
    playerTrackPresentationController: null,
    _externalSubtitleSourceLease: null,
    selectedAudioTrack: 0,
    selectedSubtitleTrack: -1,

    retryCount: 0,
    maxRetries: 3,
    hlsRecoveryCoordinator: null,
    _streamLoaderTeardownPromise: Promise.resolve(),
    _suppressNativePlaybackEvents: false,
    useProxy: true,
    fallbackAttempts: 0,
    maxFallbackAttempts: 5,
    lastFallbackTime: 0,
    fallbackCooldowns: [...FALLBACK_COOLDOWNS],

    startTime: deps.now(),
    lastProgressReport: 0,
    playbackSessionId: 0,
    playbackOrchestrator: null,
    playbackEngineTransitionController: null,
    playbackEngineActivation: null,
    nativeEngineActivation: null,
    avPlayerEngineActivation: null,
    mediaCapabilityProfile: null,
    playbackMetrics: deps.createPlaybackMetrics(),

    pipActive: false,
    networkMonitor: null,
    playbackBrowserIntegration: null,
    aspectRatioController: null,
    mobileControls: null,
    sourceFailoverController: null,
    iosPwaPlaybackController: null,
    _sourceFailoverResumeTime: null,

    avPlayer: null,
    usingAVPlayer: false,
    avPlayerAttempted: false,
    preferAVPlayer: false,
    _switchingToAVPlayer: false,

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
    _watchPartySyncHold: false,
    _emergencyStopDone: false,
    _terminalPlaybackError: false,
    iosPwaMode: deps.isIosPwaMode(),
    _lastIosPwaTapAt: 0,
    _destroyed: false,
  };
}
