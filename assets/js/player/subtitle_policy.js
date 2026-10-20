// libmedia only builds its subtitle renderer inside play(), and only when the
// `subtitle` option is on: selectSubtitle() later cannot start one, so a file
// played without it can never show an embedded subtitle. A subtitle stream with
// a zero time-base crashes that renderer's async loop (BigInt division by
// zero), so the option stays off whenever any stream has one. The caller hides
// the default track until the viewer picks one.
export function initialAVPlayerPlayOptions(streams = []) {
  const subtitles = streams.filter((stream) => stream?.mediaType === "Subtitle");
  const subtitle = subtitles.length > 0 && subtitles.every(hasPlayableSubtitleTimeBase);

  return { video: true, audio: true, subtitle };
}

export function hasPlayableSubtitleTimeBase(stream) {
  const timeBase = stream?.timeBase;
  if (!timeBase) return true;

  const numerator = Number(timeBase.num);
  const denominator = Number(timeBase.den);

  return (
    Number.isFinite(numerator) && Number.isFinite(denominator) && numerator > 0 && denominator > 0
  );
}
