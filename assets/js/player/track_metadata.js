const LANGUAGE_ALIASES = {
  ger: "de",
  fre: "fr",
  dut: "nl",
  chi: "zh",
  cze: "cs",
  gre: "el",
  rum: "ro",
  per: "fa",
  baq: "eu",
  wel: "cy",
  ice: "is",
  mac: "mk",
  may: "ms",
  arm: "hy",
  geo: "ka",
  alb: "sq",
  bur: "my",
  slo: "sk",
  tib: "bo",
  pob: "pt-BR",
  "pt-br": "pt-BR",
  por: "pt",
  eng: "en",
  spa: "es",
  jpn: "ja",
  dan: "da",
  fin: "fi",
  ita: "it",
  // Bokmål reads better to viewers as plain Norwegian.
  nob: "no",
  nb: "no",
  deu: "de",
  fra: "fr",
  nld: "nl",
  zho: "zh",
  ces: "cs",
  ell: "el",
  ron: "ro",
  fas: "fa",
  eus: "eu",
  cym: "cy",
  isl: "is",
  mkd: "mk",
  msa: "ms",
  hye: "hy",
  kat: "ka",
  sqi: "sq",
  mya: "my",
  slk: "sk",
  bod: "bo",
};

const LANGUAGE_NAMES = {
  pt: "Português",
  "pt-BR": "Português (Brasil)",
  en: "Inglês",
  es: "Espanhol",
  ja: "Japonês",
  da: "Dinamarquês",
  de: "Alemão",
  fi: "Finlandês",
  fr: "Francês",
  it: "Italiano",
  no: "Norueguês",
  nl: "Holandês",
  zh: "Chinês",
  cs: "Tcheco",
  el: "Grego",
  ro: "Romeno",
  fa: "Persa",
  eu: "Basco",
  cy: "Galês",
  is: "Islandês",
  mk: "Macedônio",
  ms: "Malaio",
  hy: "Armênio",
  ka: "Georgiano",
  sq: "Albanês",
  my: "Birmanês",
  sk: "Eslovaco",
  bo: "Tibetano",
};
const FALLBACK_TITLES = {
  pt: ["Portuguese", "Português"],
  en: ["English", "Inglês"],
  es: ["Spanish", "Español", "Espanhol"],
};
const SUBTITLE_CODECS = new Set([
  "subrip",
  "srt",
  "ass",
  "ssa",
  "webvtt",
  "mov_text",
  "dvd_subtitle",
  "hdmv_pgs_subtitle",
]);
const displayNames = new Map();
let displayNamesConstructor;
let titleLocales;

function languageCode(code) {
  const value = String(code ?? "")
    .trim()
    .toLowerCase();
  if (["", "und", "mul", "zxx"].includes(value)) return "";
  return Object.hasOwn(LANGUAGE_ALIASES, value) ? LANGUAGE_ALIASES[value] : value;
}

function displayName(code, locale) {
  try {
    if (typeof Intl.DisplayNames !== "function") return null;
    if (displayNamesConstructor !== Intl.DisplayNames) {
      displayNames.clear();
      titleLocales = null;
      displayNamesConstructor = Intl.DisplayNames;
    }
    if (!displayNames.has(locale)) {
      displayNames.set(
        locale,
        new Intl.DisplayNames([locale], { type: "language", fallback: "none" }),
      );
    }
    return displayNames.get(locale).of(code);
  } catch {
    return null;
  }
}

export function getLanguageName(code) {
  const language = languageCode(code);
  if (!language) return "";
  const name =
    displayName(language, "pt-BR") ||
    (Object.hasOwn(LANGUAGE_NAMES, language) ? LANGUAGE_NAMES[language] : null);
  return name
    ? name.charAt(0).toLocaleUpperCase("pt-BR") + name.slice(1)
    : String(code).trim().toUpperCase();
}

function normalizedTitle(value) {
  return String(value)
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .trim()
    .toLowerCase();
}

function translatedTitleLocales() {
  if (typeof Intl.DisplayNames !== "function") return [];
  if (!titleLocales) {
    // Ask the runtime which ISO 639-1 locales it actually supports, rather
    // than restricting redundant titles to English or the track's autonym.
    const letters = [..."abcdefghijklmnopqrstuvwxyz"];
    const candidates = letters.flatMap((first) => letters.map((last) => first + last));
    try {
      titleLocales = Intl.DisplayNames.supportedLocalesOf(candidates);
    } catch {
      titleLocales = Object.keys(LANGUAGE_NAMES);
    }
  }
  return titleLocales;
}

function restatesLanguage(title, code) {
  const language = languageCode(code);
  if (!language) return false;
  const base = language.split("-")[0];
  const normalized = normalizedTitle(title);
  const names = [
    language,
    base,
    code,
    getLanguageName(language),
    getLanguageName(base),
    ...(Object.hasOwn(FALLBACK_TITLES, base) ? FALLBACK_TITLES[base] : []),
  ];
  // Compare translated names as well as the language's own name (autonym).
  for (const locale of new Set(["en", base, ...translatedTitleLocales()])) {
    names.push(displayName(language, locale), displayName(base, locale));
  }
  return names.some((name) => name && normalizedTitle(name) === normalized);
}

export function hasSubtitleInLanguage(tracks, wantedLanguage) {
  if (!Array.isArray(tracks) || tracks.length === 0 || !wantedLanguage) return false;
  const wanted = languageCode(wantedLanguage).toLowerCase().split("-")[0];
  return tracks.some((track) => {
    const language = languageCode(track.language || track.lang).toLowerCase();
    const label = normalizedTitle(track.label || "");
    if (language === wanted || language.startsWith(`${wanted}-`)) return true;
    return wanted === "pt" && label.includes("portugu");
  });
}

export function formatTrackLabel(track) {
  const code = track.language || track.lang || "";
  const language = getLanguageName(code);
  const title = String(track.title ?? track.label ?? track.name ?? "").trim();
  const parts = language ? [language] : [];
  if (
    title &&
    !/^(audio|subtitle|track|faixa)\s+\d+$/i.test(title) &&
    !restatesLanguage(title, code)
  ) {
    parts.push(title);
  }
  if (parts.length === 0) parts.push(`Faixa ${(track.index ?? 0) + 1}`);
  const audio =
    track.type === "audio" ||
    (!track.type && Number(track.channels) > 0 && !SUBTITLE_CODECS.has(track.codec));
  if (audio && Number(track.channels) > 0) {
    const channels = { 1: "Mono", 2: "Estéreo", 6: "5.1", 8: "7.1" };
    parts.push(channels[track.channels] || `${track.channels}ch`);
  }
  if (track.forced && !audio) parts.push("Forçada");
  return parts.join(" · ");
}

export function findPortugueseTrack(tracks) {
  if (!tracks || tracks.length <= 1) return 0;
  const brazilian = tracks.find((track) => languageCode(track.language || track.lang) === "pt-BR");
  if (brazilian) return brazilian.index;
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
