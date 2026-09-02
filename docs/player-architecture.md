# Player architecture

## Presentation ownership

`PlayerUI` is the low-level DOM renderer. `PlayerUiController` is the presentation
boundary used by the `VideoPlayer` hook for playback state that affects the
visible player chrome:

- time and progress;
- buffered ranges and buffer health;
- loading, recovery, and terminal errors;
- play/pause state;
- playback speed;
- fullscreen state;
- Picture-in-Picture availability and state;
- control visibility and native-controls mode.

The hook supplies state and callbacks, but it must not call those `PlayerUI`
rendering methods directly. Quality, audio, and subtitle option lists remain a
separate incremental migration because they also coordinate track selection.

The Streamix player separates browser integration, playback engines, recovery,
selection policy, and product fallbacks. The goal is to keep transport-specific
state out of the Phoenix hook while preserving a single user-facing player.

## Layers

```text
VideoPlayer hook
  ├── DOM, Phoenix events, controls, Watch Party policy, PiP and Media Session
  ├── PlaybackOrchestrator
  │     ├── playback session and lifecycle
  │     ├── EngineRegistry
  │     ├── TrackCoordinator
  │     └── QoESession
  ├── source and engine fallback policy
  └── transport recovery callbacks

EngineRegistry
  ├── NativePlaybackEngine
  ├── HlsPlaybackEngine
  ├── MpegtsPlaybackEngine
  ├── AVPlayer adapter
  ├── avbridge adapter
  └── h265web adapter

Transport owners
  ├── StreamLoader owns HLS.js and MPEG-TS engines
  └── VideoPlayer currently owns advanced canvas/WASM engines
```

## Engine contract

Every playback engine implements the required surface:

```text
load
play
pause
seek
destroy
```

Capabilities such as volume, snapshots, tracks, subtitle delay, events, and
playback rate remain optional. Callers query capabilities instead of branching
on implementation names.

## Ownership

Ownership is explicit and independent from registration:

- `StreamLoader` owns the HLS.js and mpegts.js clients and their engines.
- The hook receives non-owning adapters for those transports.
- Native playback owns its media behavior but does not clear the shared video
  element during an engine transition.
- AVPlayer, avbridge, and h265web are registered as borrowed engines until their
  teardown is moved out of the hook.
- Destroying a borrowed adapter only releases the reference; it never destroys
  the underlying transport.

This rule prevents double destroy, stale listeners, and one engine clearing a
source already adopted by another engine.

## Recovery

Recovery is local to a transport, while fallback is a product decision:

```text
HlsRecoveryCoordinator
  → classify HLS errors, retry, recover media, soft reload

MpegtsRecoveryCoordinator
  → classify MPEG-TS errors, schedule retry, recreate transport

VideoPlayer
  → choose another source or engine after local recovery is exhausted
```

A recovery coordinator must not import or name another playback engine.

## Engine selection

Selection combines deterministic source facts with a bounded asynchronous
Media Capabilities probe. The probe has a short timeout and cannot block startup
indefinitely.

Inputs include:

- source/container type;
- platform and native HLS support;
- engine availability;
- codec, resolution, bitrate and frame rate;
- `supported`, `smooth`, and `powerEfficient` from Media Capabilities;
- prior device compatibility observations.

A missing or timed-out probe falls back to the deterministic selector.

## Tracks and subtitles

`TrackCoordinator` exposes one capability-based API for audio and subtitle
tracks. Engines that do not implement a capability return an empty collection
or an unsupported result; the hook does not guess based on engine identity.

External subtitle loading and subtitle delay remain optional engine
capabilities. Native browser tracks and AVPlayer-specific rendering policies
are preserved behind the same coordinator.

## QoE

`QoESession` records bounded, non-identifying playback measurements:

- startup duration;
- first-playing time;
- rebuffer count and duration;
- recovery count and duration;
- fallback count;
- engine transitions;
- terminal outcome;
- transport snapshot fields with an explicit allowlist.

URLs, provider credentials, media titles, user identifiers, and raw error
objects are never included in the browser payload. Backend telemetry uses only
bounded labels such as engine, event, state, and live/VOD mode.

## Proxy response policy

Streaming responses share a central response policy:

- explicit CORS and `Vary: Origin` behavior;
- `X-Content-Type-Options: nosniff`;
- private/no-store caching for credential-bearing media;
- `Accept-Ranges` preservation for VOD;
- proxy buffering disabled for live streams;
- no forwarding of upstream cookies or authorization headers to clients.

Range transfer, client cancellation, upstream backpressure, provider leases,
and retry budgets remain owned by their existing streaming modules.

## Diagnostics boundary

`PlayerDiagnosticsController` owns startup capability reports, error diagnosis,
and structured debug events. The `VideoPlayer` hook supplies narrow callbacks
for current playback context, event delivery, UI errors, and codec-aware ABR;
the controller does not depend on Phoenix, LiveView, or the hook implementation.

Diagnostic payloads are treated as a security boundary:

- raw playback, proxy, and provider URLs are never emitted by player debug
  events;
- the hook reports only `*_url_present` booleans when URL presence matters;
- URL-, token-, authorization-, cookie-, credential-, password-, secret-, and
  API-key-shaped fields are redacted recursively;
- URLs embedded inside diagnostic strings are replaced before transport;
- object depth, array length, and string size are bounded;
- diagnostics and event transport failures remain non-critical to playback.

Startup probes, error suggestions, and debug reports must be added through this
controller rather than implemented directly in `video_player.js`.

## Presentation coordination

`PlayerUI` remains the DOM renderer for the player. It owns element lookup,
class and attribute updates, loading timers, progress rendering, menus, and
control animations.

`PlayerUiController` is the presentation boundary used by the hook. It owns the
coordination of state that spans multiple `PlayerUI` operations:

- time, progress, buffered range, and Media Session position updates;
- loading, recovery, and terminal-error presentation;
- play/pause, playback-speed, and fullscreen visual state;
- custom-control visibility and auto-hide policy;
- retry-action binding without exposing cached DOM elements to the hook;
- Picture-in-Picture availability, active state, and bounded telemetry;
- presentation teardown.

The dependency direction is:

```text
VideoPlayer hook
    -> PlayerUiController
        -> PlayerUI
            -> DOM
```

`NativeBufferingController` and `mobile_controls.js` receive
`PlayerUiController`, not the raw DOM renderer, so buffering and input events
cannot bypass the presentation boundary.

The hook may still use `PlayerUI` directly for isolated menus and labels such as
quality, audio, subtitles, and notices. Coordinated loading, error, time,
buffer, controls, play/pause, playback speed, fullscreen, retry actions, and PiP
state must not be written directly from `video_player.js`.

`PlayerUiController` must remain independent from Phoenix, LiveView, concrete
playback engines, source selection, networking, and recovery policy. Optional
PiP telemetry failures are contained and never become playback failures.

## Browser gates

The required browser matrix is:

```text
Chromium
Firefox
WebKit
```

Two complementary gates run for every browser:

1. the full Streamix player lifecycle gate;
2. the isolated MPEG-TS engine gate using the production module and a
   deterministic browser-side transport client.

The isolated gate validates module loading, attach/load ordering, controls,
snapshot shape, and idempotent teardown without depending on a public stream.
It does not claim to validate a particular broadcaster, codec, or CDN.

## Change checklist

When adding or modifying an engine:

1. Implement the common contract and declare optional capabilities.
2. Define one owner for the concrete client.
3. Register the adapter with the correct ownership flag.
4. Keep local recovery independent from cross-engine fallback.
5. Add unit, architecture, and browser tests.
6. Run JavaScript tests, lint, asset budget, Elixir static gates, Dialyzer, the
   full test suite, and the three-browser matrix.
7. Ensure generated `priv/static` artifacts and temporary inspection files are
   not committed.

## Watch Party sync

`assets/js/hooks/watch_party_sync.js` is the composition root for the room
sync loop. It owns LiveView transport (`wp_*` events), the binding to the
player bridge (`streamixPlayback`) and the durable hold state. The decision
and timing pieces live in `assets/js/watch_party/`:

| Module | Responsibility |
|--------|----------------|
| `clock_sync.js` | ping/pong burst, best-RTT median offset, `serverNow()` |
| `command_sequencer.js` | monotonic room sequence / legacy server-time ordering |
| `command_scheduler.js` | delayed host actions under a generation counter, sync lock |
| `drift_policy.js` | pure viewer reaction (resume, pause, seek, nudge, hold, synced) |
| `sync_status.js` | status precedence, drift throttling, labels and badge classes |
| `beacon_scheduler.js` | adaptive beacon cadence |
| `reactions.js` | floating reactions and invite-copy feedback |

Modules never touch globals or LiveView directly: timers, documents and the
push function are injected, which keeps every policy testable without a
browser. `watch_party_architecture.test.js` enforces that boundary.
