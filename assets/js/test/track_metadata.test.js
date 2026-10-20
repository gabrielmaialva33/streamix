import assert from "node:assert/strict";
import test from "node:test";
import {
  findPortugueseTrack,
  formatTrackLabel,
  getLanguageName,
  hasSubtitleInLanguage,
} from "../player/track_metadata.js";

const languages = [
  ["por", "Português"],
  ["eng", "Inglês"],
  ["dan", "Dinamarquês"],
  ["ger", "Alemão"],
  ["spa", "Espanhol"],
  ["fin", "Finlandês"],
  ["fre", "Francês"],
  ["ita", "Italiano"],
  ["nob", "Norueguês"],
  ["dut", "Holandês"],
  ["pob", "Português (Brasil)"],
  ["pt-br", "Português (Brasil)"],
  ["chi", "Chinês"],
  ["cze", "Tcheco"],
  ["gre", "Grego"],
  ["rum", "Romeno"],
  ["per", "Persa"],
  ["baq", "Basco"],
  ["wel", "Galês"],
  ["ice", "Islandês"],
  ["mac", "Macedônio"],
  ["may", "Malaio"],
  ["arm", "Armênio"],
  ["geo", "Georgiano"],
  ["alb", "Albanês"],
  ["bur", "Birmanês"],
  ["slo", "Eslovaco"],
  ["tib", "Tibetano"],
  ["jpn", "Japonês"],
  ["sw", "Suaíli"],
];

test("localizes real tracks and bibliographic aliases to pt-BR", () => {
  for (const [code, name] of languages) assert.equal(getLanguageName(code), name, code);
  for (const code of ["und", "mul", "zxx", "", null, undefined]) {
    assert.equal(getLanguageName(code), "");
  }
  assert.equal(getLanguageName("qzz"), "QZZ");
  assert.equal(getLanguageName("not_a_code!"), "NOT_A_CODE!");
  for (const code of ["constructor", "__proto__", "toString"]) {
    assert.equal(getLanguageName(code), code.toUpperCase());
  }
});

test("keeps static names when Intl.DisplayNames is unavailable", (t) => {
  const original = Intl.DisplayNames;
  Intl.DisplayNames = undefined;
  t.after(() => {
    Intl.DisplayNames = original;
  });
  for (const [code, name] of languages.filter(([code]) => code !== "sw")) {
    assert.equal(getLanguageName(code), name, code);
  }
  assert.equal(getLanguageName("qzz"), "QZZ");
});

test("formats language first, drops redundant titles and retains meaningful qualifiers", () => {
  for (const label of ["Spanish", "Español", "Espanhol"]) {
    assert.equal(formatTrackLabel({ language: "spa", label }), "Espanhol");
  }
  for (const label of ["English", "Inglês", "Inglés", "Anglais", "английский"]) {
    assert.equal(formatTrackLabel({ language: "eng", label }), "Inglês");
  }
  for (const label of ["Portuguese", "Português"]) {
    assert.equal(formatTrackLabel({ language: "por", label }), "Português");
  }
  assert.equal(
    formatTrackLabel({ language: "eng", title: "SDH", codec: "subrip" }),
    "Inglês · SDH",
  );
  assert.equal(formatTrackLabel({ language: "spa", title: "European" }), "Espanhol · European");
  assert.equal(formatTrackLabel({ language: "pob", label: "Português" }), "Português (Brasil)");
  for (const label of ["Audio 3", "Subtitle 10", "Track 2", "Faixa 42", ""]) {
    assert.equal(formatTrackLabel({ index: 3, label, language: "und" }), "Faixa 4");
    assert.equal(formatTrackLabel({ index: 3, label, language: "por" }), "Português");
  }
  assert.equal(formatTrackLabel({ index: 0, language: "und", forced: true }), "Faixa 1 · Forçada");
  assert.equal(
    formatTrackLabel({ language: "eng", label: "SDH", forced: true }),
    "Inglês · SDH · Forçada",
  );
  assert.equal(formatTrackLabel({ language: "qzz" }), "QZZ");
});

test("only audio has compact channels and never exposes codec names", () => {
  for (const [channels, label] of [
    [1, "Mono"],
    [2, "Estéreo"],
    [6, "5.1"],
    [8, "7.1"],
  ]) {
    assert.equal(
      formatTrackLabel({ language: "eng", codec: "eac3", channels, type: "audio" }),
      `Inglês · ${label}`,
    );
  }
  assert.equal(formatTrackLabel({ language: "eng", codec: "eac3", channels: 6 }), "Inglês · 5.1");
  assert.equal(
    formatTrackLabel({ language: "eng", codec: "subrip", channels: 6, type: "subtitle" }),
    "Inglês",
  );
  assert.equal(formatTrackLabel({ language: "eng", codec: "subrip", channels: 6 }), "Inglês");
});

test("recognizes Portuguese subtitle metadata and prefers Brazilian Portuguese", () => {
  for (const language of ["pt-BR", "pob", "por"]) {
    assert.equal(hasSubtitleInLanguage([{ language }], "pt"), true);
  }
  assert.equal(hasSubtitleInLanguage([{ label: "Português Brasil" }], "pt-BR"), true);
  assert.equal(hasSubtitleInLanguage([{ language: "eng", label: "English" }], "pt"), false);
  const tracks = [
    { index: 0, language: "eng", label: "Inglês" },
    { index: 1, language: "por", label: "Português" },
    { index: 2, language: "pob", label: "Português (Brasil)" },
  ];
  assert.equal(findPortugueseTrack(tracks), 2);
  assert.equal(findPortugueseTrack([{ index: 0, language: "eng" }]), 0);
});
