export function initialAVPlayerPlayOptions() {
  return { video: true, audio: true, subtitle: false };
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
