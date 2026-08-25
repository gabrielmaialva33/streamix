# Player architecture

The Streamix player separates browser integration, playback engines, recovery,
selection policy, and product fallbacks. The goal is to keep transport-specific
state out of the Phoenix hook while preserving a single user-facing player.

## Layers

```text
VideoPlayer hook
  ├── DOM, Phoenix events, controls, Watch Party, PiP and Media Session
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
