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
commands delegate to `PlayerTrackController`, while the existing engine-specific
application methods remain narrow callbacks during the incremental migration:

- `applyAudioTrackSelection`;
- `applySubtitleTrackSelection`;
- `applySubtitleOffsetSelection`;
- `refreshAudioTracksLegacy`;
- `refreshSubtitleTracksLegacy`;
- `loadExternalSubtitleForAvPlayerLegacy`;
- `loadNativeExternalSubtitleForSessionLegacy`;
- `reloadNativeExternalSubtitleLegacy`.

These callback names make the remaining migration surface explicit. New event
handlers must call the public methods and must not call the legacy application
methods directly.

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

The next track slice should move implementation details behind the legacy
callbacks into focused modules. External subtitle command ownership is already
centralized; URL acquisition, native `<track>` lifecycle, presentation, and
preference persistence still remain in the hook. The order should remain:

1. preserve behavior with tests;
2. move URL acquisition and native `<track>` lifecycle;
3. move presentation and preference persistence;
4. remove each legacy callback only after all callers use the focused boundary;
5. repeat Chromium, Firefox, and WebKit gates.
