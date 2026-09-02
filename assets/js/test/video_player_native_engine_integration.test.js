import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const hookUrl = new URL("../hooks/video_player.js", import.meta.url);
const commandControllerUrl = new URL("../player/playback_command_controller.js", import.meta.url);
const nativeActivationUrl = new URL("../player/native_engine_activation.js", import.meta.url);

async function readHookSource() {
  return readFile(hookUrl, "utf8");
}

async function readCommandControllerSource() {
  return readFile(commandControllerUrl, "utf8");
}

async function readNativeActivationSource() {
  return readFile(nativeActivationUrl, "utf8");
}

function methodSource(source, name) {
  const candidates = [`  ${name}(`, `  async ${name}(`];
  const starts = candidates
    .map((candidate) => source.indexOf(candidate))
    .filter((position) => position >= 0);

  assert.equal(starts.length, 1, `expected exactly one ${name}() method`);

  const start = starts[0];
  const signatureEnd = source.indexOf(") {", start);
  assert.ok(signatureEnd >= 0, `missing method body for ${name}()`);
  const openingBrace = signatureEnd + 2;

  let depth = 0;
  let quote = null;
  let escaped = false;

  for (let index = openingBrace; index < source.length; index += 1) {
    const character = source[index];

    if (quote) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === quote) quote = null;
      continue;
    }

    if (character === '"' || character === "'" || character === "`") {
      quote = character;
    } else if (character === "{") {
      depth += 1;
    } else if (character === "}") {
      depth -= 1;
      if (depth === 0) return source.slice(start, index + 1);
    }
  }

  assert.fail(`unbalanced ${name}() method`);
}

test("the native activation creates a policy-aware NativePlaybackEngine while the hook only registers", async () => {
  const [source, activation] = await Promise.all([readHookSource(), readNativeActivationSource()]);
  const method = methodSource(source, "setMediaElementEngine");
  const createEngine = methodSource(activation, "createEngine");

  assert.match(
    activation,
    /import \{ createNativePlaybackEngine \} from "\.\/native_playback_engine\.js";/,
  );
  assert.match(createEngine, /this\.deps\.createNativePlaybackEngine\(\{/);
  assert.match(
    createEngine,
    /beforePause: \(\) => this\.host\.getNativeBufferManager\(\)\?\.markIntentionalPause\(\)/,
  );
  assert.match(
    createEngine,
    /beforeSeek: \(\) => this\.host\.getNativeBufferingController\(\)\?\.prepareSeek\(\)/,
  );
  assert.match(createEngine, /resetSourceOnDestroy: false/);

  assert.match(
    method,
    /setMediaElementEngine\(engineId, engine, \{ ownsEngine = false \} = \{\}\)/,
  );
  assert.match(method, /createPlaybackEngineAdapter\(\{ id: engineId, engine, ownsEngine \}\)/);
  assert.doesNotMatch(method, /createNativePlaybackEngine\(|createMediaElementEngine\(/);
  assert.doesNotMatch(
    source,
    /createNativePlaybackEngine|createMediaElementEngine|new NativeBufferManager|media\/native_buffer"/,
  );
});

test("native ownership is explicit while HLS and MPEG-TS stay on the shared media adapter", async () => {
  const source = await readHookSource();
  const nativeMethod = methodSource(source, "getNativePlaybackEngine");
  const managedMethod = methodSource(source, "getManagedPlaybackEngine");

  assert.match(nativeMethod, /this\.mediaElementEngine\?\.id !== ENGINE_ID\.NATIVE/);
  assert.match(nativeMethod, /this\.mediaElementEngine\.destroyed/);
  assert.match(nativeMethod, /return this\.mediaElementEngine/);

  assert.match(managedMethod, /return this\.getNativePlaybackEngine\(\);/);
  assert.doesNotMatch(managedMethod, /ENGINE_ID\.HLS/);
  assert.doesNotMatch(managedMethod, /ENGINE_ID\.MPEGTS/);
});

test("native source ownership and initial play use the engine adapter", async () => {
  const [source, activation] = await Promise.all([readHookSource(), readNativeActivationSource()]);
  const activate = methodSource(activation, "activate");
  const playAfterResume = methodSource(activation, "playAfterResume");

  assert.match(activate, /this\.host\.getNativePlaybackEngine\(\) \?\?/);
  assert.match(
    activate,
    /this\.host\.registerMediaElementEngine\(ENGINE_ID\.NATIVE, this\.createEngine\(\), \{\s*ownsEngine: true,?\s*\}\)/,
  );
  assert.match(activate, /nativeEngine\.load\(url\);/);
  assert.doesNotMatch(activate, /video\.src = /);

  assert.match(playAfterResume, /const nativeEngine = this\.host\.getNativePlaybackEngine\(\);/);
  assert.match(
    playAfterResume,
    /await \(nativeEngine \? nativeEngine\.play\(\) : video\.play\(\)\);/,
  );

  const hookPlayNative = methodSource(source, "playNative");
  const hookPlayAfterResume = methodSource(source, "playNativeAfterResume");
  assert.match(hookPlayNative, /activate\(ENGINE_SELECTION\.NATIVE\)/);
  assert.match(
    hookPlayAfterResume,
    /this\.nativeEngineActivation\?\.playAfterResume\(sessionId, resumeTime\)/,
  );
  assert.doesNotMatch(source, /this\.video\.src = this\.currentUrl/);
});

test("native reads use the adapter before canvas engines or raw media fallback", async () => {
  const source = await readCommandControllerSource();

  const expectations = [
    ["getCurrentTime", "nativeEngine.getCurrentTime()"],
    ["getDuration", "nativeEngine.getDuration()"],
    ["isPaused", "!nativeEngine.isPlaying()"],
  ];

  for (const [methodName, call] of expectations) {
    const method = methodSource(source, methodName);
    const nativeLookup = method.indexOf("const nativeEngine = this.getNativePlaybackEngine();");
    const managedLookup = method.indexOf("const engine = this.getManagedPlaybackEngine();");

    assert.ok(nativeLookup >= 0, `${methodName}() must resolve the native owner`);
    assert.ok(method.includes(call), `${methodName}() must delegate to ${call}`);
    assert.ok(
      managedLookup === -1 || nativeLookup < managedLookup,
      `${methodName}() must prefer the native adapter`,
    );
  }
});

test("transport controls share the managed contract without bypassing native policies", async () => {
  const source = await readCommandControllerSource();
  const toggle = methodSource(source, "togglePlayPause");
  const relativeSeek = methodSource(source, "seek");
  const absoluteSeek = methodSource(source, "seekTo");

  assert.match(toggle, /const engine = this\.getManagedPlaybackEngine\(\);/);
  assert.match(toggle, /engine\.pause\(\)/);
  assert.match(toggle, /engine\.play\(\)/);
  assert.match(relativeSeek, /const engine = this\.getManagedPlaybackEngine\(\);/);
  assert.match(relativeSeek, /engine\.seek\(/);
  assert.match(absoluteSeek, /const engine = this\.getManagedPlaybackEngine\(\);/);
  assert.match(absoluteSeek, /engine\.seek\(/);
});
