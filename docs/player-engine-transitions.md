# Player engine transitions

Streamix separates cross-engine transaction ordering from concrete engine and
product policy. `VideoPlayer` remains the composition root, while
`PlaybackEngineTransitionController` owns the asynchronous transaction
boundary.

## Ownership

### `PlaybackEngineTransitionController`

`assets/js/player/playback_engine_transition_controller.js` owns:

- one active transition at a time;
- capture before a new playback session begins;
- deterministic phase ordering;
- playback-session and controller-revision guards after every asynchronous
  boundary;
- teardown drain before a new concrete engine is constructed;
- cleanup of provisional engines on stale, cancelled, failed, or destroyed
  transitions;
- rollback before provisional-engine destruction;
- destruction before the product failure handler restores another engine;
- one bounded, immutable lifecycle snapshot;
- terminal, idempotent teardown.

It does not import AVPlayer, HLS.js, MPEG-TS, Phoenix, LiveView, or browser DOM
APIs. Concrete work is supplied through callbacks by the composition root.

### `AvPlayerEngineActivation`

`assets/js/player/avplayer_engine_activation.js` owns the AVPlayer family of
activations behind the explicit activation host:

- deciding whether a startup, fallback, or track-driven engine switch may run;
- constructing `AVPlayerWrapper` and its product callbacks;
- choosing the stream URL and AVPlayer load profile;
- registering the concrete adapter through the host;
- restoring canonical audio, selected tracks, media-session state, and UI;
- runtime AVPlayer-error policy after a transition has committed;
- AVPlayer-to-native recovery and the rAF progress loop.

### `VideoPlayer`

`assets/js/hooks/video_player.js` still owns:

- the circuit-breaker counters (`canAttemptFallback()`) and the AVPlayer
  preference toggle;
- the AVPlayer teardown queue that the transition controller drains;
- the thin compatibility delegates `startWithAVPlayer()`,
  `tryAVPlayerFallback()`, `switchToAVPlayerWithTrack()` and
  `stopAVPlayerTimeUpdates()`.

Neither the hook nor the activation repeats session, teardown, load, seek,
activation, and rollback guards in each native-to-AVPlayer entrypoint.

## Native to AVPlayer transaction

`AvPlayerEngineActivation.activate()` (startup), `tryFallback()` and
`switchWithTrack()` delegate to `transition()`, which composes this ordered
pipeline:

```text
capture
  -> begin playback session
  -> prepare native surface
  -> release previous AVPlayer
  -> drain teardown queue
  -> create provisional AVPlayer
  -> optional init
  -> load source
  -> register adapter
  -> restore seek, volume, and optional track
  -> activate playback intent
  -> complete product state
```

The fallback entrypoint retains circuit-breaker, attempt, telemetry, and
recommendation policy. The track entrypoint retains the requested track and
playing intent. Neither entrypoint constructs or tears down an engine directly.

## Concurrency and failure rules

Every transition captures a controller revision and playback session. A stale
completion cannot register, activate, or complete an engine for a newer
session.

A provisional engine is cleaned exactly once by the controller:

1. run the injected rollback callback;
2. destroy the provisional engine through the teardown queue;
3. invoke the product failure handler;
4. report diagnostics without replacing the original error.

An AVPlayer error emitted while a transition is still pending cancels the
transaction first, then restores native playback without asking the recovery
path to destroy the same provisional engine again. Errors emitted after commit
continue through the established runtime AVPlayer-to-native recovery path.

`cleanup()` invalidates the playback session and cancels an active transition.
Terminal hook teardown destroys the transition controller before the remaining
player resources.

## Validation contract

The focused tests cover:

- complete phase order;
- deduplication of concurrent requests;
- stale-session cleanup;
- cancellation during pending work;
- rollback and destruction ordering;
- preservation of the original failure;
- diagnostic containment;
- commit ownership;
- terminal teardown;
- architecture boundaries in the hook and in the activation modules.

Every incremental transition extraction must also keep the full JavaScript,
Elixir, Chromium, Firefox, WebKit, torrent-subtitle, and MPEG-TS gates green.

## AVPlayer to native recovery

Runtime AVPlayer failures now use the same transition controller through
`recover()` instead of a second hook-owned state machine. The ordered recovery
pipeline is:

```text
validate failed AVPlayer session
  -> capture the best resume position
  -> apply failure and recommendation policy
  -> release the AVPlayer adapter from the orchestrator
  -> destroy the failed engine through the teardown queue
  -> drain teardown
  -> begin one replacement native session
  -> restore native DOM and canonical audio presentation
  -> restart engine selection using that same session
  -> complete once
```

The controller deduplicates repeated recovery requests by transition key and
failed source session. `_avPlayerFailureSessionId` and
`_avPlayerFailurePromise` are no longer required in `VideoPlayer`.

An AVPlayer error emitted while native-to-AVPlayer construction is pending first
cancels that forward transition. Its provisional adapter is rolled back and
destroyed by the controller; recovery then runs with no second teardown. An
error emitted after commit enters recovery directly. A request arriving during
the narrow committed-but-not-yet-finalized window is queued behind the completed
forward promise rather than being mistaken for the forward transition result.

`initPlayer()` accepts an optional existing session for recovery. Ordinary
startup still creates its own session, while recovery consumes the session that
the controller created. This removes the previous double-session handoff.

Recovery failures attempt source-engine cleanup before invoking product failure
policy. Cancellation or a stale session cannot later reactivate native playback,
and diagnostic failures cannot replace the original recovery error.

## Initial AVPlayer activation

When `engine_selector` chooses AVPlayer during `initPlayer()`, the hook
dispatches through `PlaybackEngineActivation`, which calls
`AvPlayerEngineActivation.activate()` instead of entering the fallback
entrypoint. The startup route preserves the session already created by
`initPlayer()` and passes it to the transition controller. The controller uses that supplied
session instead of calling `beginPlaybackSession()` a second time.

Direct startup deliberately bypasses fallback-only policy such as the circuit
breaker, fallback counters, and fallback timestamps. It still marks AVPlayer as
attempted, records a successful AVPlayer recommendation after playback starts,
and uses the same create, explicit init, load, register, restore, activate,
rollback, teardown, and native-recovery pipeline as fallback and track-driven
switches.

A supplied startup session is validated after capture and after every later
asynchronous phase. If it has already become stale, no provisional AVPlayer is
created and no replacement session is introduced.

## Engine activation modules

Every engine decision now flows through `PlaybackEngineActivation`
(`assets/js/player/playback_engine_activation.js`), which dispatches one
activation per `engine_selector` result: HLS.js, MPEG-TS/FLV, native and AVPlayer
own their construction, loading, registration and rollback in
`hls_engine_activation.js`, `mpegts_engine_activation.js`,
`native_engine_activation.js` and `avplayer_engine_activation.js`. The hook only
builds the activation host and keeps thin compatibility delegates.

## Next extraction

The remaining hook-hosted engines are avbridge and h265web. Both share the same
canvas-engine skeleton (lazy wrapper load, adapter registration, resume seek,
AVPlayer fallback on failure) and are the next candidates for an activation
module. That recut must preserve engine-specific ownership, direct-start
policy, startup metrics, stale-session cleanup, and the existing Chromium,
Firefox, WebKit, torrent-subtitle, and MPEG-TS gates.
