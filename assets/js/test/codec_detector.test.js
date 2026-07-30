import assert from "node:assert/strict";
import test from "node:test";

import { detectHardwareAcceleration } from "../media/codec_detector.js";

test("reports WebGPU presence without requesting an adapter", async () => {
  const originalDocument = Object.getOwnPropertyDescriptor(globalThis, "document");
  const originalNavigator = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  let adapterRequests = 0;

  Object.defineProperty(globalThis, "document", {
    configurable: true,
    value: {
      createElement() {
        return {
          getContext() {
            return null;
          },
        };
      },
    },
  });

  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: {
      gpu: {
        requestAdapter() {
          adapterRequests += 1;
          return Promise.resolve(null);
        },
      },
    },
  });

  try {
    const hardware = await detectHardwareAcceleration();

    assert.equal(hardware.webgpu, true);
    assert.equal(adapterRequests, 0);
  } finally {
    restoreGlobal("document", originalDocument);
    restoreGlobal("navigator", originalNavigator);
  }
});

function restoreGlobal(name, descriptor) {
  if (descriptor) {
    Object.defineProperty(globalThis, name, descriptor);
  } else {
    Reflect.deleteProperty(globalThis, name);
  }
}
