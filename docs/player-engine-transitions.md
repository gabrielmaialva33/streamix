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

### `VideoPlayer`

`assets/js/hooks/video_player.js` still owns:

- deciding whether a fallback or track-driven engine switch is allowed;
- circuit-breaker and recommendation policy;
- constructing `AVPlayerWrapper` and its product callbacks;
- choosing the stream URL and AVPlayer load profile;
- registering the concrete adapter in `PlaybackOrchestrator`;
- restoring canonical audio, selected tracks, media-session state, and UI;
- runtime AVPlayer-error policy after a transition has committed.

The hook no longer owns the transaction order or repeats session, teardown,
load, seek, activation, and rollback guards in each native-to-AVPlayer entrypoint.

## Native to AVPlayer transaction

Both `tryAVPlayerFallback()` and `switchToAVPlayerWithTrack()` delegate to
`transitionNativeToAVPlayer()`, which composes this ordered pipeline:

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
- architecture boundaries in the hook.

Every incremental transition extraction must also keep the full JavaScript,
Elixir, Chromium, Firefox, WebKit, torrent-subtitle, and MPEG-TS gates green.

## Next extraction

The next transition family is **AVPlayer to native recovery**. It should move
these remaining responsibilities out of `VideoPlayer` without changing product
policy:

1. capture the best failure resume position;
2. forget a failed recommendation when appropriate;
3. serialize AVPlayer teardown;
4. restore native DOM and canonical audio presentation;
5. begin the replacement native session;
6. restart engine selection exactly once;
7. deduplicate runtime error events and failed-transition recovery.

That recut should reuse the same controller primitives rather than introduce a
second transition state machine.
