import assert from "node:assert/strict";
import test from "node:test";
import { bufferDiagnosticsEnabled } from "../player/player_diagnostics_visibility.js";

test("shows buffer seconds only for an explicit Streamix debug session", () => {
  assert.equal(bufferDiagnosticsEnabled({ __STREAMIX_DEBUG__: true }), true);
  assert.equal(bufferDiagnosticsEnabled({ __STREAMIX_DEBUG__: false }), false);
  assert.equal(bufferDiagnosticsEnabled({}), false);
  assert.equal(bufferDiagnosticsEnabled(null), false);
});
