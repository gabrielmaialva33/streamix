const LANGUAGE_NAMES = {
  por: "Português",
  pt: "Português",
  "pt-BR": "Português (BR)",
  eng: "English",
  en: "English",
  spa: "Español",
  es: "Español",
  jpn: "Japanese",
  ja: "Japanese",
  und: "Indefinido",
};

export function getLanguageName(code) {
  return LANGUAGE_NAMES[code] || code;
}

export function hasSubtitleInLanguage(tracks, wantedLanguage) {
  if (!Array.isArray(tracks) || tracks.length === 0 || !wantedLanguage) return false;

  const wanted = wantedLanguage.toLowerCase().split("-")[0];

  return tracks.some((track) => {
    const language = String(track.language || "").toLowerCase();
    const label = String(track.label || "")
      .normalize("NFD")
      .replace(/\p{Diacritic}/gu, "")
      .toLowerCase();

    if (language === wanted || language.startsWith(`${wanted}-`)) return true;
    if (wanted === "pt") {
      return ["por", "pob"].includes(language) || label.includes("portugu");
    }

    return false;
  });
}

export function formatTrackLabel(track) {
  const parts = [];

  if (
    track.label &&
    track.label !== `Audio ${track.index + 1}` &&
    track.label !== `Subtitle ${track.index + 1}`
  ) {
    parts.push(track.label);
  }

  if (track.language) {
    const languageName = getLanguageName(track.language);
    if (!parts.includes(languageName)) parts.push(languageName);
  }

  if (track.codec) parts.push(`(${track.codec})`);
  if (track.channels && track.channels > 0) parts.push(`${track.channels}ch`);

  return parts.length > 0 ? parts.join(" ") : `Track ${track.index + 1}`;
}

export function findPortugueseTrack(tracks) {
  if (!tracks || tracks.length <= 1) return 0;

  const patterns = [/\bpt[-_]?br\b/i, /\bportugu[eê]s?\b/i, /\bbrazil/i, /\bpt\b/i, /\bpor\b/i];

  for (const pattern of patterns) {
    const found = tracks.find(
      (track) =>
        pattern.test(String(track.language || "")) || pattern.test(String(track.label || "")),
    );

    if (found) return found.index;
  }

  return 0;
}
