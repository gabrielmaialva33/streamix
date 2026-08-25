# Player tracks architecture

Streamix separates engine-level track capabilities from product-level track
commands.

## Responsibilities

### `TrackCoordinator`

`assets/js/player/track_coordinator.js` is the low-level engine boundary. It
normalizes track metadata and invokes only capabilities exposed by the active
playback engine:

- audio and subtitle track discovery;
- audio and subtitle selection;
- external subtitle loading;
- subtitle delay.

It does not own UI state, preferences, LiveView events, or player lifecycle.

### `HlsPlaybackEngine`

`assets/js/player/hls_playback_engine.js` is the sole owner of hls.js audio and
subtitle state. It exposes discovery and selection through the shared playback
engine contract, including the active track marker used by `TrackCoordinator`.
`StreamLoader` may forward those capabilities, but it no longer reads or writes
`hls.audioTracks`, `hls.audioTrack`, `hls.subtitleTracks`, or
`hls.subtitleTrack` directly.

### `PlayerTrackController`

`assets/js/player/player_track_controller.js` is the product command boundary.
It owns:

- one public entry point for audio, subtitle, subtitle-offset, and external
  subtitle commands;
- deduplication of an identical in-flight selection or subtitle load;
- independent revisions for unrelated track operations;
- protection against stale asynchronous completions;
- operation snapshots for diagnostics;
- teardown and rejection of late player writes;
- non-critical error reporting.

The controller deliberately does not import HLS.js, MPEG-TS, AVPlayer,
avbridge, h265web, Phoenix, or the player hook.

### `VideoPlayer`

`assets/js/hooks/video_player.js` remains the composition root. Public track
commands delegate to `PlayerTrackController`. HLS discovery and selection now
flow through `PlaybackOrchestrator` → `TrackCoordinator` → `HlsPlaybackEngine`.
The hook only converts normalized track metadata into product UI/events and
persists the user preference.

The remaining engine-specific application callbacks are:

- `applyAudioTrackSelection` for the transitional AVPlayer branch plus product
  persistence/events;
- `applySubtitleTrackSelection` for the transitional native/AVPlayer branches
  plus product persistence/events;
- `applySubtitleOffsetSelection`;
- `loadExternalSubtitleForAvPlayerLegacy`;
- `loadNativeExternalSubtitleForSessionLegacy`;
- `reloadNativeExternalSubtitleLegacy`.

The generic `refreshAudioTracksFromActiveEngine` and
`refreshSubtitleTracksFromActiveEngine` methods consume only the active engine
contract. New event handlers must call the public methods and must not access
hls.js track properties directly.

## Concurrency rules

Audio, subtitle, offset, refresh, and external subtitle operations have
independent revisions. A slow audio selection cannot invalidate a subtitle
selection that completed in the meantime. Repeating an equivalent pending
selection or external subtitle load returns the existing promise instead of
issuing a second engine command.

A completion may update the applied snapshot only when:

1. the controller has not been destroyed; and
2. it is still the newest revision for that operation type.

## Error behavior

The original operation error is preserved. The optional diagnostic callback is
contained so a telemetry or logging failure cannot replace the playback error.
Synchronous operations remain synchronous; asynchronous operations preserve
their original promise result.

## Next extraction

The next track slice should move AVPlayer discovery and selection behind an
AVPlayer engine/adapter capability. After that, native external subtitles can
move into a focused controller and resolver. The order should remain:

1. preserve behavior with tests;
2. move AVPlayer track discovery/selection behind the engine contract;
3. move URL acquisition and native `<track>` lifecycle;
4. move presentation and preference persistence;
5. remove each legacy callback only after all callers use the focused boundary;
6. repeat Chromium, Firefox, and WebKit gates.
