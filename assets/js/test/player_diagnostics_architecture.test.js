import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const hookSource = () => readFile(new URL("../hooks/video_player.js", import.meta.url), "utf8");

const controllerSource = () =>
  readFile(new URL("../player/player_diagnostics_controller.js", import.meta.url), "utf8");

test("diagnostics orchestration stays independent from the VideoPlayer hook", async () => {
  const source = await controllerSource();

  assert.doesNotMatch(source, /hooks\/video_player|phoenix|live_view/iu);
  assert.match(source, /class PlayerDiagnosticsController/);
  assert.match(source, /sanitizeDiagnosticPayload/);
});

test("VideoPlayer delegates startup, error and debug diagnostics to the controller", async () => {
  const source = await hookSource();

  assert.match(source, /createPlayerDiagnosticsController\(\{[\s\S]*?getResourcePolicy:/u);
  assert.match(
    source,
    /runStartupDiagnostics\(\) \{\s*return this\.diagnosticsController\?\.runStartup\(\) \?\? null;/u,
  );
  assert.match(source, /this\.diagnosticsController\.showError\(/u);
  assert.match(source, /runDiagnostics/u);
  assert.match(
    source,
    /reportPlayerDebug\(stage, extra = \{\}\) \{\s*return this\.diagnosticsController\?\.reportDebug\(stage, extra\) \?\? null;/u,
  );
});

test("VideoPlayer debug events never include raw playback URLs", async () => {
  const source = await hookSource();

  assert.doesNotMatch(source, /current_url:\s*this\.currentUrl/u);
  assert.doesNotMatch(source, /stream_url:\s*this\.streamUrl/u);
  assert.doesNotMatch(source, /proxy_url:\s*this\.proxyUrl/u);
  assert.match(source, /current_url_present:\s*Boolean\(this\.currentUrl\)/u);
  assert.match(source, /stream_url_present:\s*Boolean\(this\.streamUrl\)/u);
  assert.match(source, /proxy_url_present:\s*Boolean\(this\.proxyUrl\)/u);
});

test("the hook no longer imports low-level diagnostic implementations", async () => {
  const source = await hookSource();

  assert.doesNotMatch(source, /import \{ diagnoseError \}/u);
  assert.doesNotMatch(source, /import \{ collectStartupDiagnostics \}/u);
});
