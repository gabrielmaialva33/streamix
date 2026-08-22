export function isPictureInPictureActive({ documentRef = globalThis.document, video } = {}) {
  return !!(
    (documentRef?.pictureInPictureElement && documentRef.pictureInPictureElement === video) ||
    video?.webkitPresentationMode === "picture-in-picture"
  );
}

export function isPictureInPictureSupported({
  canvasPlaybackActive = false,
  documentRef = globalThis.document,
  video,
} = {}) {
  if (canvasPlaybackActive || !video) return false;

  const standard =
    documentRef?.pictureInPictureEnabled === true &&
    typeof video.requestPictureInPicture === "function" &&
    !video.disablePictureInPicture;
  const webkit =
    typeof video.webkitSupportsPresentationMode === "function" &&
    video.webkitSupportsPresentationMode("picture-in-picture");

  return !!(standard || webkit);
}

export async function togglePictureInPicture({ documentRef = globalThis.document, video } = {}) {
  if (!isPictureInPictureSupported({ documentRef, video })) return false;

  if (documentRef?.pictureInPictureElement === video) {
    await documentRef.exitPictureInPicture();
  } else if (
    documentRef?.pictureInPictureEnabled === true &&
    typeof video.requestPictureInPicture === "function"
  ) {
    await video.requestPictureInPicture();
  } else if (video.webkitPresentationMode === "picture-in-picture") {
    video.webkitSetPresentationMode("inline");
  } else {
    video.webkitSetPresentationMode("picture-in-picture");
  }

  return isPictureInPictureActive({ documentRef, video });
}

export async function exitPictureInPicture({ documentRef = globalThis.document, video } = {}) {
  if (documentRef?.pictureInPictureElement === video) {
    await documentRef.exitPictureInPicture();
  } else if (video?.webkitPresentationMode === "picture-in-picture") {
    video.webkitSetPresentationMode("inline");
  }

  return isPictureInPictureActive({ documentRef, video });
}
