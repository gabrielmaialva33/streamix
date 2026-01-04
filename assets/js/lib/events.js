/**
 * Event Constants
 *
 * Centralized event names to avoid typos and ease refactoring.
 */

// Player UI Events (dispatched from controls)
export const PLAYER_EVENTS = {
  TOGGLE_PLAY: "player:toggle-play",
  TOGGLE_MUTE: "player:toggle-mute",
  TOGGLE_FULLSCREEN: "player:toggle-fullscreen",
  TOGGLE_PIP: "player:toggle-pip",
  SET_SPEED: "player:set-speed",
  TOGGLE_AVPLAYER: "player:toggle-avplayer",
};

// LiveView Events (pushed to server)
export const LIVEVIEW_EVENTS = {
  // Player state
  PLAYER_INITIALIZING: "player_initializing",
  PLAYER_ERROR: "player_error",
  STREAMING_MODE_CHANGED: "streaming_mode_changed",
  BUFFERING: "buffering",

  // Quality/Tracks
  QUALITY_CHANGED: "quality_changed",
  QUALITY_SWITCHED: "quality_switched",
  QUALITIES_AVAILABLE: "qualities_available",
  AUDIO_TRACK_CHANGED: "audio_track_changed",
  AUDIO_TRACKS_AVAILABLE: "audio_tracks_available",
  SUBTITLE_TRACK_CHANGED: "subtitle_track_changed",
  SUBTITLE_TRACKS_AVAILABLE: "subtitle_tracks_available",

  // Playback
  PROGRESS_UPDATE: "progress_update",
  DURATION_AVAILABLE: "duration_available",
  UPDATE_WATCH_TIME: "update_watch_time",
  PLAYBACK_RATE_CHANGED: "playback_rate_changed",

  // Controls
  PIP_TOGGLED: "pip_toggled",
  PIP_ERROR: "pip_error",
  MUTE_TOGGLED: "mute_toggled",
  VOLUME_CHANGED: "volume_changed",

  // AVPlayer
  AVPLAYER_PREFERENCE_CHANGED: "avplayer_preference_changed",

  // Token refresh
  REQUEST_TOKEN_REFRESH: "request_token_refresh",
};

// LiveView Commands (received from server)
export const LIVEVIEW_COMMANDS = {
  SET_QUALITY: "set_quality",
  SET_AUDIO_TRACK: "set_audio_track",
  SET_SUBTITLE_TRACK: "set_subtitle_track",
  TOGGLE_PIP: "toggle_pip",
  SET_STREAMING_MODE: "set_streaming_mode",
  SEEK: "seek",
  SET_PLAYBACK_RATE: "set_playback_rate",
  REFRESH_TOKEN: "refresh_token",
};

// HLS.js Events (subset of commonly used)
export const HLS_EVENTS = {
  MANIFEST_PARSED: "hlsManifestParsed",
  LEVEL_SWITCHED: "hlsLevelSwitched",
  ERROR: "hlsError",
  FRAG_LOADED: "hlsFragLoaded",
  AUDIO_TRACKS_UPDATED: "hlsAudioTracksUpdated",
  SUBTITLE_TRACKS_UPDATED: "hlsSubtitleTracksUpdated",
};

// MPEG-TS Events
export const MPEGTS_EVENTS = {
  MEDIA_INFO: "mediaInfo",
  STATISTICS_INFO: "statisticsInfo",
  ERROR: "error",
};

export default {
  PLAYER_EVENTS,
  LIVEVIEW_EVENTS,
  LIVEVIEW_COMMANDS,
  HLS_EVENTS,
  MPEGTS_EVENTS,
};
