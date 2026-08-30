import { createPlaybackCommandController } from "../../player/playback_command_controller.js";

export function settleCommands() {
  return new Promise((resolve) => setImmediate(resolve));
}

export function createPlaybackCommandHarness({
  state: stateOverrides = {},
  video: videoOverrides = {},
  boundaries = {},
} = {}) {
  const calls = {
    debug: [],
    emitted: [],
    errors: [],
    events: [],
    notices: [],
    positions: [],
    rates: [],
    speed: [],
    states: [],
  };
  const root = {};

  const video = {
    paused: true,
    currentTime: 10,
    duration: 100,
    playbackRate: 1,
    seekable: { length: 0, start: () => 0, end: () => 0 },
    canPlayType: () => "",
    async play() {
      video.paused = false;
    },
    pause() {
      video.paused = true;
    },
    ...videoOverrides,
  };

  const audio = { muted: false, volume: 0.5 };
  const state = {
    contentType: "movie",
    expectedDuration: 0,
    managedEngine: null,
    nativeEngine: null,
    denied: false,
    syncHeld: false,
    rateSupported: true,
    partyMode: false,
    video,
    ...stateOverrides,
  };

  const audioController = {
    toggleMute() {
      audio.muted = !audio.muted;
      return { ...audio };
    },
    adjustVolume(delta) {
      audio.volume = Math.max(0, Math.min(1, audio.volume + delta));
      return { ...audio };
    },
  };

  const controller = createPlaybackCommandController({
    getRoot: () => root,
    getVideo: () => state.video,
    getContentType: () => state.contentType,
    getExpectedDuration: () => state.expectedDuration,
    getManagedPlaybackEngine: () => state.managedEngine,
    getNativePlaybackEngine: () => state.nativeEngine,
    rejectViewerTransportControl: () => state.denied,
    isWatchPartySyncHeld: () => state.syncHeld,
    supportsPlaybackRateControl: () => state.rateSupported,
    isPartyMode: () => state.partyMode,
    getAudioController: () => audioController,
    getNativeBufferManager: () => null,
    getNativeBufferingController: () => null,
    getPlayerUiController: () => ({
      updateSpeedUI: (rate) => calls.speed.push(rate),
    }),
    getPlayerUi: () => ({
      showNotice: (notice) => calls.notices.push(notice),
    }),
    setPlaybackSystemState: (playbackState) => calls.states.push(playbackState),
    updateMediaSessionPosition: (options) => calls.positions.push(options),
    pushEvent: (event, payload) => calls.events.push({ event, payload }),
    emitPlaybackEvent: (target, event) => calls.emitted.push({ target, event }),
    savePlaybackRate: (rate) => calls.rates.push(rate),
    onDebug: (...args) => calls.debug.push(args),
    onError: (...args) => calls.errors.push(args),
    ...boundaries,
  });

  return { audio, calls, controller, root, state, video };
}
