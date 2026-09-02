import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import test from "node:test";

const hookUrl = new URL("../hooks/watch_party_sync.js", import.meta.url);
const modulesDirUrl = new URL("../watch_party/", import.meta.url);

async function source(url) {
  return readFile(url, "utf8");
}

async function moduleSources() {
  const names = (await readdir(modulesDirUrl)).filter((name) => name.endsWith(".js")).sort();
  const sources = await Promise.all(names.map((name) => source(new URL(name, modulesDirUrl))));
  return names.map((name, index) => [name, sources[index]]);
}

test("watch party modules are pure or explicitly injected, never LiveView or hook aware", async () => {
  const modules = await moduleSources();
  assert.deepEqual(
    modules.map(([name]) => name),
    [
      "beacon_scheduler.js",
      "clock_sync.js",
      "command_scheduler.js",
      "command_sequencer.js",
      "drift_policy.js",
      "player_binding.js",
      "player_policy.js",
      "reactions.js",
      "sync_status.js",
    ],
  );

  for (const [name, text] of modules) {
    assert.doesNotMatch(text, /pushEvent|handleEvent|LiveSocket|Phoenix|hooks\//, name);
    if (name !== "player_binding.js") {
      assert.doesNotMatch(
        text,
        /streamixPlayback|__watchPartySyncHook/,
        `${name} must not know the player bridge`,
      );
    }
    assert.doesNotMatch(
      text,
      /\bdocument\.|\bwindow\.|getElementById\(\s*"/,
      `${name} must not touch globals`,
    );
    assert.doesNotMatch(
      text,
      /(?<![.\w])(?:setTimeout|setInterval|clearTimeout|clearInterval)\(/,
      `${name} must use an injected timer api`,
    );
  }

  const pure = modules.filter(([name]) =>
    ["drift_policy.js", "sync_status.js", "command_sequencer.js"].includes(name),
  );
  for (const [name, text] of pure) {
    assert.doesNotMatch(text, /timerApi|globalThis/, `${name} must stay timer-free`);
  }
});

test("the sync hook composes the modules and keeps only transport, binding and hold state", async () => {
  const hook = await source(hookUrl);

  for (const factory of [
    "createClockSync",
    "createCommandSequencer",
    "createSyncCommandScheduler",
    "createBeaconScheduler",
    "createReactionPresenter",
  ]) {
    assert.match(hook, new RegExp(`this\\.\\w+ = ${factory}\\(`), `hook must compose ${factory}`);
  }
  assert.match(hook, /resolveDriftCorrection\(\{/);
  assert.match(hook, /resolveSyncStatus\(\{/);
  assert.match(hook, /renderSyncStatus\(element, \{/);
  assert.match(hook, /_setup\(\) \{/);
  assert.match(hook, /_defineAccessors\(\) \{/);
  assert.doesNotMatch(
    hook,
    /^\s{2}(?:get|set) \w+\(/m,
    "hook object literals must not declare accessors: LiveView copies them as static values",
  );

  for (const leakedInternal of [
    "clockOffsetSamples",
    "clockPings",
    "lastServerSequence",
    "pendingCommandTimers",
    "reactionTimers",
    "beaconInterval",
    "catchup: 1000",
    "Math.abs(drift)",
    "normalized * normalized",
    "Aguardando o buffer",
    "bg-warning/90",
    "floating-reaction",
    "execCommand",
    "navigator.clipboard",
    "streamixPlayback",
    "canPlayType",
    "PLAYBACK_BRIDGE_EVENT",
    "streamix:buffering",
    "playerWaitTimer",
    'getElementById("video-player-container")',
  ]) {
    assert.equal(
      hook.includes(leakedInternal),
      false,
      `${leakedInternal} must live in a watch party module`,
    );
  }

  assert.match(hook, /this\.binding = createWatchPartyPlayerBinding\(\{/);
  assert.match(hook, /define\(\s*"playback",\s*\(\) => this\.binding\?\.playback \?\? null,/);
  for (const retained of [
    "_ensurePlayerBinding(",
    "_unbindPlayer(",
    "_safePush(",
    "_setSyncHold(",
    "this.pushEvent(",
  ]) {
    assert.ok(hook.includes(retained), `${retained} stays on the hook for now`);
  }
});

test("the player hook delegates Watch Party policy to the shared module", async () => {
  const player = await source(new URL("../hooks/video_player.js", import.meta.url));

  assert.match(
    player,
    /import \{ createWatchPartyPlayerPolicy \} from "\.\.\/watch_party\/player_policy\.js";/,
  );
  assert.match(player, /this\.watchPartyPolicy = createWatchPartyPlayerPolicy\(\{/);
  for (const delegate of [
    "applyPartyControlPolicy() { return this.watchPartyPolicy?.applyControlPolicy() ?? false; }",
    "setWatchPartySyncHold(held) { return this.watchPartyPolicy?.setSyncHold(held) ?? true; }",
    "canControlPartyTransport(options = {}) { return this.watchPartyPolicy?.canControlTransport(options) ?? true; }",
    "rejectViewerTransportControl(options = {}) { return this.watchPartyPolicy?.rejectViewerTransportControl(options) ?? false; }",
  ]) {
    assert.ok(player.replace(/\s+/g, " ").includes(delegate), `missing thin delegate: ${delegate}`);
  }

  for (const leaked of [
    "_watchPartySyncHold",
    'partyRole === "viewer"',
    'partyRole === "host"',
    "Reprodução controlada pelo anfitrião",
    "A reprodução é controlada pelo anfitrião.",
    "markIntentionalPause();\n      this.video.pause();",
    "this.hls = ",
    "this.mpegtsPlayer",
    "setHlsClient",
    "setMpegtsPlayer",
  ]) {
    assert.equal(player.includes(leaked), false, `${leaked} must not remain on the player hook`);
  }
});
