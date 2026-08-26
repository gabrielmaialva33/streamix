# Player tracks architecture

Streamix separates engine-level track capabilities, native subtitle lifecycle,
and product-level track commands. The hook coordinates presentation,
preferences, and LiveView events; it does not read or write decoder-specific
track state or manipulate native `<track>` elements directly.

## Responsibilities

### `TrackCoordinator`

`assets/js/player/track_coordinator.js` is the active-engine boundary. It:

- normalizes heterogeneous audio and subtitle metadata;
- refreshes synchronous HLS tracks and asynchronous AVPlayer tracks through one
  API;
- caches immutable snapshots per active engine;
- invalidates cached tracks when the active engine changes;
- rejects stale asynchronous discovery results;
- translates a product/UI index into the concrete selector expected by the
  engine;
- invokes audio selection, subtitle selection, external-subtitle loading, and
  subtitle delay capabilities;
- reports engine failures without allowing diagnostics to replace the original
  asynchronous error.

It does not own UI state, preferences, LiveView events, source selection, native
DOM tracks, or cross-engine fallback.

### `HlsPlaybackEngine`

`assets/js/player/hls_playback_engine.js` is the sole owner of hls.js track
properties. Code outside that engine must not read or write:

- `hls.audioTracks`;
- `hls.audioTrack`;
- `hls.subtitleTracks`;
- `hls.subtitleTrack`.

The engine exposes immutable track snapshots and an explicit `selectionId`
corresponding to the hls.js array index. `StreamLoader` owns the HLS transport
lifecycle but delegates track discovery and selection to this engine.

### `AVPlayerWrapper`

`assets/js/media/avplayer_wrapper.js` owns AVPlayer-specific track operations:

- asynchronous audio and subtitle discovery;
- concrete stream-ID selection;
- external subtitle injection;
- subtitle delay;
- AVPlayer-specific audio resynchronization after a track switch.

The wrapper returns stable operation results. `TrackCoordinator` maps Streamix's
menu indexes to the concrete AVPlayer stream IDs, so `VideoPlayer` never calls
these decoder methods directly.

### `NativeSubtitleController`

`assets/js/player/native_subtitle_controller.js` owns the lifecycle of the
external subtitle used by native HTML media playback. It is responsible for:

- detecting an already available native subtitle in the requested language;
- creating, appending, replacing, and removing one `<track kind="subtitles">`;
- switching the native text-track mode between `disabled` and `showing`;
- owning and releasing the source lease supplied for that track;
- debouncing offset-triggered reloads;
- invalidating late asynchronous results by operation revision and playback
  session;
- exposing an immutable lifecycle and track snapshot;
- reusable session reset and terminal, idempotent teardown;
- containing optional diagnostics and source-cleanup failures.

The controller receives a releasable source from its `resolveSource` boundary. It
does not know IMDb IDs, API routes, Phoenix, LiveView, product preferences, or
subtitle menus.

### `SubtitleSourceResolver`

`assets/js/player/subtitle_source_resolver.js` owns external subtitle
acquisition and temporary source creation. It is responsible for:

- building the subtitle API request from IMDb ID, language, and bounded offset;
- deduplicating concurrent requests for the same playback session and source
  key;
- caching successful and unavailable responses within the active session;
- aborting superseded or reset requests when `AbortController` is available;
- rejecting late responses after a playback-session or resolver revision
  change;
- creating independent, immutable Object URL leases for each consumer;
- revoking every active Object URL exactly once on lease release, reset, or
  destroy;
- bounding its response cache and exposing a compact immutable snapshot;
- containing fetch, Blob, Object URL, cleanup, and diagnostic failures.

The resolver does not select tracks, render menus, persist preferences, inject
subtitles into a playback engine, or emit Phoenix/LiveView events.

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
avbridge, h265web, native subtitle DOM code, Phoenix, or the player hook.

### `PlayerTrackPresentationController`

`assets/js/player/player_track_presentation_controller.js` owns product-level
track presentation. It is responsible for:

- staging immutable normalized audio and subtitle lists before preference
  selection;
- choosing a saved valid audio track or the Portuguese fallback;
- preserving explicit subtitle-disable policy and saved subtitle selection;
- rendering audio and subtitle menus through injected UI boundaries;
- persisting successful user and preference-driven selections;
- emitting track availability and selection events;
- formatting and rendering the bounded subtitle-offset label;
- presenting native subtitle snapshots without owning the native `<track>`;
- discarding presentation completions from stale playback sessions or older
  asynchronous refreshes;
- exposing an immutable presentation snapshot and terminal teardown.

It does not call playback engines, inspect HLS/AVPlayer internals, create native
tracks, acquire subtitle sources, query the DOM, or import Phoenix/LiveView.
Selection commands are injected from `VideoPlayer` and still enter through
`PlayerTrackController`.

### `VideoPlayer`

`assets/js/hooks/video_player.js` remains the composition root. Its track work is
limited to:

- rendering normalized options;
- applying and persisting product preferences;
- emitting LiveView/product events;
- deciding when an external subtitle should be requested;
- composing `PlayerTrackController`, `TrackCoordinator`, and
  `NativeSubtitleController`;
- coordinating transitions between playback engines.

HLS and AVPlayer discovery, selection, and delay run through
`PlaybackOrchestrator -> TrackCoordinator -> active engine`. Native selection,
replacement, reload timing, and teardown run through
`NativeSubtitleController`.

External subtitle acquisition now runs through `SubtitleSourceResolver`. The
hook supplies product inputs such as IMDb ID, requested language, playback
session, and engine policy. It may retain the accepted AVPlayer lease while that
engine uses the source, but it no longer constructs API URLs, performs the
subtitle fetch, reads WebVTT, creates Blob URLs, or revokes Object URLs.

## Concurrency rules

Audio, subtitle, offset, refresh, and external subtitle operations have
independent revisions. A slow audio selection cannot invalidate a subtitle
selection that completed in the meantime. Repeating an equivalent pending
selection or external subtitle load returns the existing promise instead of
issuing a second engine command.

Track discovery has a second boundary inside `TrackCoordinator`: every refresh
is tied to both the active engine object and a per-kind revision. A late
AVPlayer response cannot overwrite tracks belonging to a newer engine or newer
refresh.

Native subtitle loading has its own session and revision guard. A source that
resolves after cleanup, reset, teardown, or a playback-session change is never
attached and its release callback is executed exactly once. Offset reloads are
debounced so only the newest requested offset is applied.

`SubtitleSourceResolver` adds a separate request boundary. Concurrent consumers
of the same session, IMDb ID, language, and offset share network work but receive
independently owned Object URL leases. A force refresh invalidates older pending
work, while reset and destroy abort pending requests and reject every late
completion.

A completion may update the applied product snapshot only when:

1. the responsible controller has not been destroyed;
2. it is still the newest revision for that operation type; and
3. the playback session that requested it is still current.

## Source ownership

Every generated Blob source is created by `SubtitleSourceResolver` and returned
as a lease:

```text
{ source, release() }
```

For native playback, `NativeSubtitleController` owns the lease while its track
is attached and releases it on replacement, reset, stale completion, or
destroy. For AVPlayer, `VideoPlayer` temporarily retains the accepted lease and
## Transition boundary

The track subsystem has explicit owners for commands, engine capabilities,
presentation, native DOM, and external source acquisition. Its remaining hook
methods are thin adapters used while engines change.

`PlaybackEngineTransitionController` now owns all AVPlayer transaction routes:

- native fallback to AVPlayer;
- track-driven native to AVPlayer switches;
- AVPlayer runtime recovery back to native;
- direct AVPlayer activation selected during initial engine policy.

The direct-start route reuses the playback session already created by
`initPlayer()` and bypasses fallback-only counters and circuit-breaker policy.
It still uses the same create, init, load, register, restore, activate, rollback,
teardown, and native-recovery guarantees.

See `docs/player-engine-transitions.md` for the phase model, ownership rules,
session-reuse contract, and validation matrix. The next transition recut should
make provisional-engine destruction transition-specific before moving the first
non-AVPlayer engine family into the controller.
