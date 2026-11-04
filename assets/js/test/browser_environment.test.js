import assert from "node:assert/strict";
import test from "node:test";
import PwaInstall from "../hooks/pwa_install.js";

test("install telemetry recognizes navigator.standalone without a matching media query", (t) => {
  const oldWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
  const oldNavigator = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  Object.defineProperty(globalThis, "window", {
    configurable: true,
    value: { matchMedia: () => ({ matches: false }) },
  });
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: { standalone: true },
  });
  t.after(() => {
    if (oldWindow) Object.defineProperty(globalThis, "window", oldWindow);
    else delete globalThis.window;
    if (oldNavigator) Object.defineProperty(globalThis, "navigator", oldNavigator);
    else delete globalThis.navigator;
  });
  let payload;
  PwaInstall.reportTelemetry.call(
    {
      pushEvent: (_event, data) => {
        payload = data;
      },
    },
    "pwa_install_help_opened",
  );
  assert.equal(payload.display_mode, "standalone");
});

test("desktop iPad and hybrid touch devices keep independent touch and hover capabilities", async () => {
  const { hasTouch, canHover, isAppleTouch, isStandalone } = await import(
    "../core/browser_environment.js"
  );
  const ipad = {
    navigatorRef: { platform: "MacIntel", userAgent: "Macintosh", maxTouchPoints: 5 },
    windowRef: { matchMedia: () => ({ matches: false }) },
  };
  assert.equal(hasTouch(ipad), true);
  assert.equal(isAppleTouch(ipad), true);
  assert.equal(canHover(ipad), false);
  const hybrid = {
    navigatorRef: { platform: "Win32", maxTouchPoints: 10 },
    windowRef: { ontouchstart: null, matchMedia: () => ({ matches: true }) },
  };
  assert.equal(hasTouch(hybrid), true);
  assert.equal(canHover(hybrid), true);
  assert.equal(isAppleTouch(hybrid), false);
  assert.equal(isStandalone({ navigatorRef: { standalone: true }, windowRef: {} }), true);
  assert.equal(isStandalone({ navigatorRef: {}, windowRef: {} }), false);
  assert.equal(canHover({ windowRef: {} }), true);
  assert.equal(canHover({ windowRef: { ontouchstart: null } }), false);
});
