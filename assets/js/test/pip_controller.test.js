import assert from "node:assert/strict";
import test from "node:test";

import {
  exitPictureInPicture,
  isPictureInPictureSupported,
  togglePictureInPicture,
} from "../player/pip_controller.js";

test("standard Picture-in-Picture toggles entry and exit", async () => {
  const documentRef = {
    pictureInPictureElement: null,
    pictureInPictureEnabled: true,
    async exitPictureInPicture() {
      this.pictureInPictureElement = null;
    },
  };
  const video = {
    disablePictureInPicture: false,
    async requestPictureInPicture() {
      documentRef.pictureInPictureElement = video;
    },
  };

  assert.equal(isPictureInPictureSupported({ documentRef, video }), true);
  assert.equal(await togglePictureInPicture({ documentRef, video }), true);
  assert.equal(documentRef.pictureInPictureElement, video);
  assert.equal(await togglePictureInPicture({ documentRef, video }), false);
  assert.equal(documentRef.pictureInPictureElement, null);
});

test("WebKit presentation mode toggles without the standard API", async () => {
  const modes = [];
  const video = {
    webkitPresentationMode: "inline",
    webkitSupportsPresentationMode: (mode) => mode === "picture-in-picture",
    webkitSetPresentationMode(mode) {
      modes.push(mode);
      this.webkitPresentationMode = mode;
    },
  };

  assert.equal(isPictureInPictureSupported({ documentRef: {}, video }), true);
  assert.equal(await togglePictureInPicture({ documentRef: {}, video }), true);
  assert.equal(await exitPictureInPicture({ documentRef: {}, video }), false);
  assert.deepEqual(modes, ["picture-in-picture", "inline"]);
});

test("canvas playback disables Picture-in-Picture capability", () => {
  const video = {
    disablePictureInPicture: false,
    requestPictureInPicture() {},
  };
  const documentRef = { pictureInPictureEnabled: true };

  assert.equal(
    isPictureInPictureSupported({
      canvasPlaybackActive: true,
      documentRef,
      video,
    }),
    false,
  );
});

test("a failed browser exit rejects for the caller to contain", async () => {
  const video = {};
  const documentRef = {
    pictureInPictureElement: video,
    async exitPictureInPicture() {
      throw new Error("browser rejected exit");
    },
  };

  await assert.rejects(exitPictureInPicture({ documentRef, video }), /browser rejected exit/);
});
