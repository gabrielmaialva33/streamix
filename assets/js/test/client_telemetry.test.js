import assert from "node:assert/strict";
import test from "node:test";

import {
  classifyDeviceClass,
  surfaceForPath,
  webVitalPayload,
} from "../telemetry/client_telemetry.js";

test("classifies paths without sending a raw route", () => {
  assert.equal(surfaceForPath("/watch/movie/42?token=secret"), "watch");
  assert.equal(surfaceForPath("/providers/9/movies"), "browse");
  assert.equal(surfaceForPath("/admin/users"), "admin");
});

test("rounds and bounds web vitals into the persistence contract", () => {
  assert.deepEqual(
    webVitalPayload({
      batchId: "batch-1",
      path: "/watch/movie/42?token=secret",
      displayMode: "standalone",
      deviceClass: "mobile",
      lcp: 1234.8,
      inp: -4,
      cls: 0.1254,
    }),
    {
      batch_id: "batch-1",
      kind: "web_vital",
      event: "page_vitals",
      surface: "watch",
      display_mode: "standalone",
      device_class: "mobile",
      lcp_ms: 1235,
      inp_ms: 0,
      cls_milli: 125,
    },
  );
});

test("classifies device segments without retaining the user agent", () => {
  assert.equal(classifyDeviceClass({ mobileHint: true }), "mobile");
  assert.equal(classifyDeviceClass({ mobileHint: false, viewportWidth: 320 }), "desktop");
  assert.equal(
    classifyDeviceClass({
      coarsePointer: true,
      maxTouchPoints: 5,
      viewportWidth: 1024,
    }),
    "mobile",
  );
  assert.equal(classifyDeviceClass({ maxTouchPoints: 0, viewportWidth: 390 }), "desktop");
});
