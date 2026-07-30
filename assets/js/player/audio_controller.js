import {
  adjustAudioVolume,
  audioOutputVolume,
  hydrateAudioState,
  setAudioVolume,
  toggleAudioMute,
} from "./audio_state.js";
import { perceivedToLinear } from "./volume_utils.js";

const copyState = (state) => ({ ...state });

export function createAudioController({
  initialPreferences = {},
  applyOutput,
  render,
  saveVolume,
  saveMuted,
}) {
  let state = hydrateAudioState(initialPreferences);

  const getState = () => copyState(state);

  const outputSnapshot = () => ({
    volume: state.volume,
    outputVolume: audioOutputVolume(state),
    muted: state.muted,
  });

  const publish = ({ persistVolume = false, persistMuted = false } = {}) => {
    applyOutput(outputSnapshot());

    if (persistVolume) saveVolume(state.volume);
    if (persistMuted) saveMuted(state.muted);

    render(getState());
    return getState();
  };

  return {
    getState,

    replaceState(preferences) {
      state = hydrateAudioState(preferences);
      return getState();
    },

    applyOutput() {
      const snapshot = outputSnapshot();
      applyOutput(snapshot);
      return snapshot;
    },

    render() {
      const snapshot = getState();
      render(snapshot);
      return snapshot;
    },

    setVolume(volume) {
      state = setAudioVolume(state, volume);
      return publish({
        persistVolume: true,
        persistMuted: state.volume > 0,
      });
    },

    toggleMute() {
      const previousVolume = state.volume;
      state = toggleAudioMute(state);

      return publish({
        persistVolume: state.volume !== previousVolume,
        persistMuted: true,
      });
    },

    adjustVolume(delta) {
      state = adjustAudioVolume(state, delta);
      return publish({
        persistVolume: true,
        persistMuted: state.volume > 0,
      });
    },

    syncNativeState({ outputVolume, muted }) {
      const expectedOutputVolume = audioOutputVolume(state);
      const volumeMismatch = Math.abs(outputVolume - expectedOutputVolume) > 0.01;
      const mutedMismatch = muted !== state.muted;

      if (!volumeMismatch && !mutedMismatch) return false;

      if (!muted && outputVolume === 0) {
        state = toggleAudioMute({ ...state, muted: true });
      } else {
        state = {
          ...setAudioVolume(state, perceivedToLinear(outputVolume)),
          muted,
        };
      }

      publish({ persistVolume: true, persistMuted: true });
      return true;
    },
  };
}
