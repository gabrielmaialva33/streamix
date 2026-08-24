# Streaming stack and delivery practices — August 2026

This document records the player-library decisions and delivery practices used
by Streamix as of August 24, 2026. It is intentionally narrower than a generic
player comparison: the recommendations account for the existing engine
contract, custom UI, Phoenix LiveView integration, Watch Party, torrent/GIndex
sources, and multi-browser test matrix.

## Selected client stack

| Capability | Streamix choice | Rationale |
| --- | --- | --- |
| HLS over MSE | `hls.js` 1.7.x | Focused HLS implementation, LL-HLS, fMP4 and MPEG-TS, alternate audio/subtitles, CMCD, Content Steering, and direct access to recovery primitives |
| Native HLS | Browser `<video>` path, selected explicitly | Preferred only when the runtime's native implementation is the more reliable path, especially Apple platforms |
| Legacy TS/FLV | `mpegts.js` 1.8.x | Preserves Xtream/live compatibility without contaminating the HLS engine contract |
| Complex codecs and containers | Existing AVPlayer, avbridge, and h265web paths | Kept behind specialized engines and loaded only when selected |
| Browser journeys | Playwright matrix: Chromium, Firefox, WebKit | Protects real media lifecycle, mobile controls, resume behavior, and Apple-like WebKit behavior |

## Why HLS.js remains the primary adaptive engine

HLS.js is the best fit for the current product because Streamix already owns:

- the player UI and interaction model;
- engine selection and fallback;
- QoE and lifecycle telemetry;
- source resolution and proxy policies;
- Watch Party synchronization;
- native, HLS, MPEG-TS, and specialized codec engines.

Replacing that architecture with a full player framework would create two
competing orchestration layers. HLS.js should therefore remain a transport
engine behind `PlaybackEngineAdapter`, not become the owner of product UI or
cross-engine fallback.

The HLS engine owns:

- one hls.js client instance;
- source loading;
- media attachment;
- same-engine soft reload;
- playback controls exposed by the common contract;
- HLS diagnostics and deterministic teardown.

`StreamLoader` continues to own:

- hls.js construction and configuration;
- session cancellation;
- event wiring;
- adaptive buffer management;
- recovery commands;
- cross-engine fallback.

`VideoPlayer` borrows the HLS engine through a non-owning adapter. It must not
destroy a transport still owned by `StreamLoader`.

## Alternatives and when to reconsider

### Shaka Player

Shaka is a strong option when DASH, EME/DRM, and offline IndexedDB playback are
central requirements. It should be reconsidered only if Streamix adopts those
capabilities broadly enough to justify replacing the current transport layer.
Using Shaka only for ordinary HLS would duplicate ABR, networking, recovery,
and track-management responsibilities already present in the project.

### Video.js

Video.js remains useful when a product wants a complete player framework,
plugin ecosystem, and standardized UI. Streamix already has a custom UI,
LiveView bridge, engine contract, mobile controls, and Watch Party behavior, so
introducing Video.js would add a second component and lifecycle architecture.

### WebCodecs

WebCodecs is a low-level codec API and remains a W3C Working Draft. It is
appropriate for specialized decode pipelines, frame processing, or unsupported
container/codec paths. It is not a replacement for HLS manifest handling,
adaptive bitrate selection, MSE buffering, encrypted media, or native media
controls.

## Authoring and packaging baseline

For content controlled by Streamix or a cooperating origin:

1. Prefer CMAF-compatible fragmented MP4 for modern HLS delivery.
2. Package HEVC in fragmented MP4 and retain an H.264 fallback rendition for
   clients without HEVC support.
3. Keep keyframe boundaries aligned across renditions. A two-second keyframe
   cadence is the practical compatibility baseline unless a measured use case
   requires another value.
4. Keep audio/video timestamps and segment boundaries aligned across variants.
5. Publish accurate `CODECS`, resolution, frame-rate, and bandwidth attributes.
6. Validate manifests before deployment and test actual segment playback, not
   only playlist parsing.

## Low-Latency HLS

LL-HLS is an opt-in delivery profile, not a client-side flag alone.

- Use partial segments and blocking playlist reload only when the origin and CDN
  preserve the required request and caching semantics.
- A one-second part target is the current Apple authoring recommendation.
- `PART-HOLD-BACK` must be at least three part targets.
- Clients must be able to fall back to regular-latency HLS when the server's
  low-latency profile is incomplete or invalid.
- Track live latency, drift, stalls, and skipped playlist updates separately
  from ordinary VOD metrics.

Do not enable low-latency mode globally for third-party IPTV sources. Select it
only for providers that have demonstrated correct LL-HLS behavior.

## Networking and security

- Every playlist, rendition, segment, key, subtitle, and initialization segment
  fetched by HLS.js must satisfy CORS.
- Use HTTPS/TLS for manifests and media resources.
- Prefer short-lived signed URLs or cookies for protected media; never expose
  upstream provider credentials to browser logs, telemetry, or permanent URLs.
- Preserve range requests and cache validators through proxies.
- Avoid query-string mutation after signing a URL.
- Keep credential exchange and redirect resolution server-side.
- Treat manifests, subtitle files, and metadata as untrusted input.

## Adaptive bitrate and codec selection

- Start conservatively when there is no trustworthy bandwidth history.
- Avoid oscillation by requiring meaningful headroom before an upward switch.
- Preserve a lower emergency rendition for poor mobile networks.
- Use `navigator.mediaCapabilities.decodingInfo()` when available to distinguish
  codec support from smooth and power-efficient playback.
- Use runtime codec support as the final authority. A manifest advertising HEVC,
  AV1, or Dolby Vision does not mean that every browser/OS combination can
  decode it.

## Telemetry

The minimum per-session telemetry set is:

- engine and selected source;
- startup success and terminal failure;
- time to first frame;
- startup bitrate;
- rebuffer count and total rebuffer duration;
- quality switches and switch reason;
- estimated bandwidth;
- current and target live latency;
- fallback attempts and outcome;
- fatal HLS error type/details;
- playback completion reason.

Use bounded labels. URLs, content IDs, user IDs, provider credentials, and raw
error payloads must not become metric labels.

CMCD should be enabled only after confirming that the CDN/origin consumes it and
that request overhead and privacy expectations are acceptable. HLS.js 1.7.x
supports the modern CMCD path, but Streamix should roll it out per provider or
per controlled CDN rather than globally.

## CI gate

The `e2e` job in `.github/workflows/docker.yml` is a required build dependency
and runs the same browser journeys in parallel for:

```text
Player E2E / chromium
Player E2E / firefox
Player E2E / webkit
```

The browser test container version is derived from the repository's locked
Playwright version. PostgreSQL and Redis are isolated services, RabbitMQ is
disabled, and a failure in one browser does not cancel the other matrix entries.

## Upgrade policy

- Use patch releases after the unit, asset, and three-browser gates pass.
- Review HLS.js minor releases for changes to ABR, LL-HLS, codec filtering,
  worker behavior, and recovery semantics.
- Keep `hls.js` and its Playwright coverage in the same pull request when a
  release changes runtime behavior.
- Do not change HLS.js, MPEG-TS, and specialized codec engines in one migration.
- Preserve rollback by keeping each engine implementation independently
  selectable.

## Primary references

- HLS.js package and documentation: <https://www.npmjs.com/package/hls.js>
- HLS.js repository: <https://github.com/video-dev/hls.js>
- Apple HTTP Live Streaming: <https://developer.apple.com/streaming/>
- Apple HLS Authoring Specification: <https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices>
- W3C WebCodecs: <https://www.w3.org/TR/webcodecs/>
- W3C Media Capabilities: <https://www.w3.org/TR/media-capabilities/>
- Shaka Player: <https://github.com/shaka-project/shaka-player>
- mpegts.js: <https://github.com/xqq/mpegts.js>
