import { readFileSync as readRawSource } from "node:fs";

// Architecture checks cover the hook and its extracted collaborators. Read real
// files without rewriting imports so checks still validate production boundaries.
const collaborators = ["player_composition.js", "player_session_lifecycle.js"];
export function readSourceSync(url, encoding = "utf8") {
  const source = readRawSource(url, encoding);
  if (!url.pathname.endsWith("/hooks/video_player.js")) return source;
  return [
    ...collaborators.map((name) =>
      readRawSource(new URL(`../../player/${name}`, import.meta.url), encoding),
    ),
    source,
  ].join("\n");
}

export async function readSource(url, encoding = "utf8") {
  return readSourceSync(url, encoding);
}
