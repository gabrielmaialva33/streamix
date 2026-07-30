import assert from "node:assert/strict";
import test from "node:test";
import {
  findPortugueseTrack,
  formatTrackLabel,
  getLanguageName,
  hasSubtitleInLanguage,
} from "../player/track_metadata.js";

test("formats track metadata without repeating its language", () => {
  assert.equal(
    formatTrackLabel({
      index: 0,
      label: "Português",
      language: "por",
      codec: "aac",
      channels: 2,
    }),
    "Português (aac) 2ch",
  );

  assert.equal(formatTrackLabel({ index: 1, label: "Audio 2" }), "Track 2");
  assert.equal(getLanguageName("jpn"), "Japanese");
});

test("recognizes Portuguese subtitle metadata", () => {
  assert.equal(hasSubtitleInLanguage([{ language: "pt-BR" }], "pt"), true);
  assert.equal(hasSubtitleInLanguage([{ label: "Português Brasil" }], "pt-BR"), true);
  assert.equal(hasSubtitleInLanguage([{ language: "eng", label: "English" }], "pt"), false);
});

test("selects pt-BR before generic Portuguese tracks", () => {
  const tracks = [
    { index: 0, language: "eng", label: "English" },
    { index: 1, language: "por", label: "Português" },
    { index: 2, language: "pt-BR", label: "Brazilian" },
  ];

  assert.equal(findPortugueseTrack(tracks), 2);
  assert.equal(findPortugueseTrack([{ index: 0, language: "eng" }]), 0);
});
