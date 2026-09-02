import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const avplayerWrapperUrl = new URL("../media/avplayer_wrapper.js", import.meta.url);
const controllerUrl = new URL("../player/player_track_controller.js", import.meta.url);
const hlsEngineUrl = new URL("../player/hls_playback_engine.js", import.meta.url);
const hookUrl = new URL("../hooks/video_player.js", import.meta.url);
const nativeSubtitleControllerUrl = new URL(
  "../player/native_subtitle_controller.js",
  import.meta.url,
);
const subtitleSourceResolverUrl = new URL("../player/subtitle_source_resolver.js", import.meta.url);
const playerStateUrl = new URL("../player/player_state.js", import.meta.url);
const streamLoaderUrl = new URL("../media/stream_loader.js", import.meta.url);

async function source(url) {
  return readFile(url, "utf8");
}

test("PlayerTrackController remains independent of engines, Phoenix, and the hook", async () => {
  const controller = await source(controllerUrl);

  assert.doesNotMatch(controller, /phoenix|liveview|video_player/i);
  assert.doesNotMatch(controller, /hls|mpegts|avplayer|avbridge|h265web|native_playback/i);
  assert.doesNotMatch(controller, /document\.|window\.|querySelector/);
});

test("HLS track state stays behind the playback engine contract", async () => {
  const [hlsEngine, hook, streamLoader] = await Promise.all([
    source(hlsEngineUrl),
    source(hookUrl),
    source(streamLoaderUrl),
  ]);

  assert.doesNotMatch(hook, /\bhls\.(audioTracks|audioTrack|subtitleTracks|subtitleTrack)\b/);
  assert.doesNotMatch(
    streamLoader,
    /this\.hls\.(audioTracks|audioTrack|subtitleTracks|subtitleTrack)\b/,
  );
  assert.match(hlsEngine, /getAudioTracks\(\)/);
  assert.match(hlsEngine, /getSubtitleTracks\(\)/);
  assert.match(hlsEngine, /selectAudioTrack\(trackIndex\)/);
  assert.match(hlsEngine, /selectSubtitleTrack\(trackIndex\)/);
  assert.match(hlsEngine, /selectionId: index/);
  assert.match(streamLoader, /this\.hlsEngine\?\.selectAudioTrack\?\.\(trackIndex\)/);
  assert.match(streamLoader, /this\.hlsEngine\?\.selectSubtitleTrack\?\.\(trackIndex\)/);
});

test("AVPlayer track details stay behind its wrapper and the active-engine coordinator", async () => {
  const [avplayerWrapper, hook] = await Promise.all([source(avplayerWrapperUrl), source(hookUrl)]);

  for (const capability of [
    "getAudioTracks",
    "getSubtitleTracks",
    "selectAudioTrack",
    "selectSubtitleTrack",
    "loadExternalSubtitle",
    "setSubtitleDelay",
  ]) {
    assert.match(avplayerWrapper, new RegExp(`${capability}\\(`));
  }

  assert.doesNotMatch(
    hook,
    /this\.avPlayer\.(getAudioTracks|getSubtitleTracks|selectAudioTrack|selectSubtitleTrack|loadExternalSubtitle|setSubtitleDelay)\(/,
  );
  assert.doesNotMatch(
    hook,
    /setAVPlayerAudioTrack|setAVPlayerSubtitleTrack|applyAVPlayerSubtitleDelay|loadExternalSubtitleForAvPlayerLegacy/,
  );
  assert.match(hook, /this\.playbackOrchestrator\?\.refreshAudioTracks\(\)/);
  assert.match(hook, /this\.playbackOrchestrator\?\.refreshSubtitleTracks\(\)/);
  assert.match(hook, /this\.playbackOrchestrator\.selectAudioTrack\(trackIndex\)/);
  assert.match(hook, /this\.playbackOrchestrator\.selectSubtitleTrack\(trackIndex\)/);
  assert.match(hook, /this\.playbackOrchestrator\?\.loadExternalSubtitle\(\{/);
  assert.match(hook, /this\.playbackOrchestrator\?\.setSubtitleDelay\(/);
});

test("native subtitle DOM lifecycle stays behind NativeSubtitleController", async () => {
  const [controller, hook, playerState] = await Promise.all([
    source(nativeSubtitleControllerUrl),
    source(hookUrl),
    source(playerStateUrl),
  ]);

  assert.match(controller, /export class NativeSubtitleController/);
  assert.match(controller, /video\.textTracks/);
  assert.match(controller, /createTrackElement/);
  assert.match(controller, /scheduleReload\(options = \{\}, onComplete = null\)/);
  assert.match(controller, /_releaseLease\(lease\)/);
  assert.doesNotMatch(controller, /hooks\/video_player|pushEvent|LiveSocket|Phoenix/);

  assert.match(
    hook,
    /import \{ createNativeSubtitleController \} from "\.\.\/player\/native_subtitle_controller\.js";/,
  );
  assert.match(hook, /this\.nativeSubtitleController = createNativeSubtitleController\(\{/);
  assert.match(hook, /this\.nativeSubtitleController\?\.select\(trackIndex\)/);
  assert.match(hook, /this\.nativeSubtitleController\?\.scheduleReload\(/);
  assert.match(hook, /this\.nativeSubtitleController\.load\(\{/);
  assert.match(hook, /this\.nativeSubtitleController\?\.reload\(\{/);
  assert.match(hook, /this\.nativeSubtitleController\?\.reset\(\)/);
  assert.match(hook, /this\.nativeSubtitleController\?\.destroy\(\)/);

  assert.doesNotMatch(hook, /document\.createElement\(["']track["']\)/);
  assert.doesNotMatch(hook, /this\.video\.textTracks/);
  assert.doesNotMatch(
    hook,
    /_nativeExternalSubtitleTrack|_nativeExternalSubtitleReloading|_subtitleOffsetReloadTimer/,
  );
  assert.doesNotMatch(
    hook,
    /loadNativeExternalSubtitleForSessionLegacy|reloadNativeExternalSubtitleLegacy/,
  );

  assert.match(playerState, /subtitleSourceResolver: null/);
  assert.match(playerState, /nativeSubtitleController: null/);
  assert.match(playerState, /_externalSubtitleSourceLease: null/);
  assert.doesNotMatch(
    playerState,
    /_externalSubtitleLoadedFor|_nativeExternalSubtitleTrack|_nativeExternalSubtitleReloading|_subtitleOffsetReloadTimer|_externalSubtitleBlobUrl/,
  );
});

test("external subtitle acquisition stays behind SubtitleSourceResolver", async () => {
  const [resolver, hook, nativeController, playerState] = await Promise.all([
    source(subtitleSourceResolverUrl),
    source(hookUrl),
    source(nativeSubtitleControllerUrl),
    source(playerStateUrl),
  ]);

  assert.match(resolver, /export class SubtitleSourceResolver/);
  assert.match(resolver, /export function buildSubtitleRequestUrl/);
  assert.match(resolver, /\/api\/subtitles\//);
  assert.match(resolver, /this\._fetch\(/);
  assert.match(resolver, /this\._createBlob\(/);
  assert.match(resolver, /this\._createObjectURL\(/);
  assert.match(resolver, /this\._revokeObjectURL\(/);
  assert.match(resolver, /this\._pending = new Map\(\)/);
  assert.match(resolver, /reset\(\)/);
  assert.match(resolver, /destroy\(\)/);
  assert.doesNotMatch(resolver, /hooks\/video_player|pushEvent|LiveSocket|Phoenix/);

  assert.match(
    hook,
    /import \{ createSubtitleSourceResolver \} from "\.\.\/player\/subtitle_source_resolver\.js";/,
  );
  assert.match(hook, /this\.subtitleSourceResolver = createSubtitleSourceResolver\(\{/);
  assert.match(hook, /this\.subtitleSourceResolver\?\.resolve\(\{/);
  assert.match(hook, /this\.subtitleSourceResolver\?\.reset\(\)/);
  assert.match(hook, /this\.subtitleSourceResolver\?\.destroy\(\)/);
  assert.doesNotMatch(hook, /fetchExternalSubtitleSource|_externalSubtitleLoadedFor/);
  assert.doesNotMatch(hook, /URL\.createObjectURL|URL\.revokeObjectURL/);
  assert.doesNotMatch(hook, /new Blob\(\[vtt\]/);
  assert.doesNotMatch(hook, /\/api\/subtitles\//);

  assert.doesNotMatch(nativeController, /\/api\/subtitles\//);
  assert.doesNotMatch(nativeController, /URL\.createObjectURL|URL\.revokeObjectURL/);
  assert.doesNotMatch(nativeController, /new Blob\(/);
  assert.match(playerState, /subtitleSourceResolver: null/);
  assert.doesNotMatch(playerState, /_externalSubtitleLoadedFor/);
});

test("VideoPlayer creates one track controller with narrow composition boundaries", async () => {
  const hook = await source(hookUrl);

  assert.match(
    hook,
    /import \{ createPlayerTrackController \} from "\.\.\/player\/player_track_controller\.js";/,
  );
  assert.match(hook, /this\.playerTrackController = createPlayerTrackController\(\{/);
  assert.match(hook, /refreshAudioTracks: \(\) => this\.refreshAudioTracksFromActiveEngine\(\)/);
  assert.match(
    hook,
    /refreshSubtitleTracks: \(\) => this\.refreshSubtitleTracksFromActiveEngine\(\)/,
  );
  assert.match(
    hook,
    /selectAudioTrack: \(trackIndex\) => this\.applyAudioTrackSelection\(trackIndex\)/,
  );
  assert.match(
    hook,
    /selectSubtitleTrack: \(trackIndex\) =>\s*this\.applySubtitleTrackSelection\(trackIndex\)/,
  );
  assert.match(
    hook,
    /setSubtitleOffset: \(offsetMs\) => this\.applySubtitleOffsetSelection\(offsetMs\)/,
  );
  assert.match(
    hook,
    /loadExternalSubtitle: \(\.\.\.args\) =>\s*this\.loadExternalSubtitleForActiveEngine\(\.\.\.args\)/,
  );
  assert.match(
    hook,
    /loadNativeExternalSubtitle: \(\.\.\.args\) =>\s*this\.loadNativeExternalSubtitleForSession\(\.\.\.args\)/,
  );
  assert.match(
    hook,
    /reloadNativeExternalSubtitle: \(\.\.\.args\) =>\s*this\.reloadNativeExternalSubtitleForSession\(\.\.\.args\)/,
  );
});

test("public track commands delegate through PlayerTrackController", async () => {
  const hook = await source(hookUrl);

  assert.match(
    hook,
    /setAudioTrack\(trackIndex\) \{\s*if \(this\.playerTrackController\) \{\s*return this\.playerTrackController\.selectAudioTrack\(trackIndex\);/,
  );
  assert.match(
    hook,
    /updateAudioTracks\(\) \{\s*if \(this\.playerTrackController\) \{\s*return this\.playerTrackController\.refreshAudioTracks\(\);/,
  );
  assert.match(
    hook,
    /setSubtitleTrack\(trackIndex\) \{\s*if \(this\.playerTrackController\) \{\s*return this\.playerTrackController\.selectSubtitleTrack\(trackIndex\);/,
  );
  assert.match(
    hook,
    /async setSubtitleOffset\(offsetMs\) \{\s*if \(this\.playerTrackController\) \{\s*return this\.playerTrackController\.setSubtitleOffset\(offsetMs\);/,
  );
  assert.match(
    hook,
    /updateSubtitleTracks\(\) \{\s*if \(this\.playerTrackController\) \{\s*return this\.playerTrackController\.refreshSubtitleTracks\(\);/,
  );
  assert.match(
    hook,
    /async loadExternalSubtitleIfAvailable\(\.\.\.args\) \{\s*if \(this\.playerTrackController\) \{\s*return this\.playerTrackController\.loadExternalSubtitle\(\.\.\.args\);/,
  );
  assert.match(
    hook,
    /async loadNativeExternalSubtitleIfAvailable\(\.\.\.args\) \{\s*if \(this\.playerTrackController\) \{\s*return this\.playerTrackController\.loadNativeExternalSubtitle\(\.\.\.args\);/,
  );
  assert.match(
    hook,
    /async reloadNativeExternalSubtitle\(\.\.\.args\) \{\s*if \(this\.playerTrackController\) \{\s*return this\.playerTrackController\.reloadNativeExternalSubtitle\(\.\.\.args\);/,
  );
});

test("track controller lifecycle is tied to the player lifecycle", async () => {
  const hook = await source(hookUrl);

  assert.match(hook, /this\.nativeSubtitleController\?\.reset\(\);/);
  assert.match(hook, /this\.subtitleSourceResolver\?\.reset\(\);/);
  assert.match(hook, /this\.nativeSubtitleController\?\.destroy\(\);/);
  assert.match(hook, /this\.subtitleSourceResolver\?\.destroy\(\);/);
  assert.match(hook, /this\.playerTrackController\?\.destroy\(\);/);
  assert.ok(
    hook.indexOf("this.nativeSubtitleController?.destroy();") <
      hook.indexOf("this.subtitleSourceResolver?.destroy();"),
  );
  assert.ok(
    hook.indexOf("this.subtitleSourceResolver?.destroy();") <
      hook.indexOf("this.playerTrackController?.destroy();"),
  );
  assert.ok(
    hook.indexOf("this.playerTrackController?.destroy();") <
      hook.indexOf("this.playerUIController?.destroy();"),
  );
});

test("track presentation stays behind PlayerTrackPresentationController", async () => {
  const presentationUrl = new URL(
    "../player/player_track_presentation_controller.js",
    import.meta.url,
  );
  const playerStateUrl = new URL("../player/player_state.js", import.meta.url);
  const playerUiUrl = new URL("../player/player_ui.js", import.meta.url);
  const [presentation, hook, playerState, playerUi] = await Promise.all([
    source(presentationUrl),
    source(hookUrl),
    source(playerStateUrl),
    source(playerUiUrl),
  ]);

  assert.match(presentation, /export class PlayerTrackPresentationController/);
  assert.match(presentation, /presentAudioTracks\(/);
  assert.match(presentation, /presentAudioSelection\(/);
  assert.match(presentation, /presentSubtitleTracks\(/);
  assert.match(presentation, /presentSubtitleSelection\(/);
  assert.match(presentation, /presentSubtitleOffset\(/);
  assert.match(presentation, /presentNativeSubtitleSnapshot\(/);
  assert.match(presentation, /clearSubtitlePresentation\(/);
  assert.match(presentation, /findPortugueseTrack\(/);
  assert.match(presentation, /formatTrackLabel\(/);
  assert.doesNotMatch(
    presentation,
    /PlaybackOrchestrator|TrackCoordinator|HlsPlaybackEngine|AVPlayerWrapper|Phoenix|LiveSocket|pushEvent/,
  );
  assert.doesNotMatch(presentation, /document\.|window\.|querySelector/);

  assert.match(
    hook,
    /import \{ createPlayerTrackPresentationController \} from "\.\.\/player\/player_track_presentation_controller\.js";/,
  );
  assert.match(
    hook,
    /this\.playerTrackPresentationController = createPlayerTrackPresentationController\(\{/,
  );
  assert.match(hook, /this\.playerTrackPresentationController\?\.presentAudioSelection\(/);
  assert.match(hook, /this\.playerTrackPresentationController\?\.presentAudioTracks\(/);
  assert.match(hook, /this\.playerTrackPresentationController\?\.presentSubtitleSelection\(/);
  assert.match(hook, /this\.playerTrackPresentationController\?\.presentSubtitleTracks\(/);
  assert.match(hook, /this\.playerTrackPresentationController\?\.presentSubtitleOffset\(/);
  assert.match(hook, /this\.playerTrackPresentationController\?\.presentNativeSubtitleSnapshot\(/);
  assert.match(hook, /this\.playerTrackPresentationController\?\.clearSubtitlePresentation\(/);

  assert.doesNotMatch(hook, /saveAudioTrack\(/);
  assert.doesNotMatch(hook, /saveSubtitleTrack\(/);
  assert.doesNotMatch(hook, /findPortugueseTrack|formatTrackLabel/);
  assert.doesNotMatch(
    hook,
    /audio_tracks_available|subtitle_tracks_available|audio_track_changed|subtitle_track_changed/,
  );
  assert.doesNotMatch(hook, /querySelector\(["']#subtitle-sync-value["']\)/);

  const injectedRenderCalls =
    hook.match(/this\.playerUI\?\.(updateAudioOptions|updateSubtitleOptions)/g) ?? [];
  assert.equal(injectedRenderCalls.length, 2);
  assert.match(playerUi, /updateSubtitleOffsetLabel\(label\)/);
  assert.match(playerState, /playerTrackPresentationController: null/);

  assert.match(hook, /this\.playerTrackPresentationController\?\.destroy\(\);/);
  assert.ok(
    hook.indexOf("this.playerTrackController?.destroy();") <
      hook.indexOf("this.playerTrackPresentationController?.destroy();"),
  );
  assert.ok(
    hook.indexOf("this.playerTrackPresentationController?.destroy();") <
      hook.indexOf("this.playerUIController?.destroy();"),
  );
});

test("the background track probe and probed selections live in TrackProbeController", async () => {
  const [hook, controller] = await Promise.all([
    source(new URL("../hooks/video_player.js", import.meta.url)),
    source(new URL("../player/track_probe_controller.js", import.meta.url)),
  ]);

  assert.match(
    hook,
    /import \{ createTrackProbeController \} from "\.\.\/player\/track_probe_controller\.js";/,
  );
  assert.match(hook, /this\.trackProbeController = createTrackProbeController\(\{/);
  assert.match(
    hook,
    /probeMetadataInBackground\(\) \{\s*return this\.trackProbeController\?\.probe\(\)/,
  );
  assert.match(
    hook,
    /handleProbedAudioTrackSelect\(trackIndex\) \{\s*return this\.trackProbeController\?\.selectAudioTrack\(trackIndex\)/,
  );
  assert.match(
    hook,
    /handleProbedSubtitleTrackSelect\(trackIndex\) \{\s*return this\.trackProbeController\?\.selectSubtitleTrack\(trackIndex\)/,
  );
  assert.doesNotMatch(
    hook,
    /_probedAudioTracks|_probedSubtitleTracks|_metadataProbed|api\/gindex-tracks/,
  );

  assert.match(controller, /TRACK_PROBE_HOST_METHODS = Object\.freeze\(\[/);
  assert.match(controller, /this\.host\.presentProbedTracks\(\{/);
  assert.match(controller, /this\.host\.switchToAVPlayerWithTrack\(/);
  assert.doesNotMatch(
    controller,
    /hooks\/video_player|pushEvent|LiveSocket|Phoenix|document\.|window\./,
  );
});
