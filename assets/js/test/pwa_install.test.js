import assert from "node:assert/strict";
import test from "node:test";

import { promptForPwaInstall, pwaInstallMode } from "../lib/pwa_install.js";

test("prefers the installed and native states before iOS instructions", () => {
  assert.equal(
    pwaInstallMode({ standalone: true, iosWebKit: true, hasNativePrompt: true }),
    "installed",
  );
  assert.equal(
    pwaInstallMode({ standalone: false, iosWebKit: true, hasNativePrompt: true }),
    "native",
  );
  assert.equal(
    pwaInstallMode({ standalone: false, iosWebKit: true, hasNativePrompt: false }),
    "ios",
  );
  assert.equal(pwaInstallMode(), "unavailable");
});

test("normalizes the browser install prompt result", async () => {
  let prompted = false;
  const result = await promptForPwaInstall({
    prompt: async () => {
      prompted = true;
    },
    userChoice: Promise.resolve({ outcome: "accepted", platform: "web" }),
  });

  assert.equal(prompted, true);
  assert.deepEqual(result, { outcome: "accepted", platform: "web" });
  assert.deepEqual(await promptForPwaInstall(null), {
    outcome: "unavailable",
    platform: null,
  });
});
