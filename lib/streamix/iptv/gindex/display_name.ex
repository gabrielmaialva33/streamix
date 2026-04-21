defmodule Streamix.Iptv.Gindex.DisplayName do
  @moduledoc """
  Turns raw gindex filenames/folder names into something pleasant to
  read in the UI.

  Two flavours:

    * `clean_title/1` — strip release-scene noise from a movie/series
      title (delegates to `ReleaseParser` for the heavy lifting, falls
      back to the raw string if parsing returns empty).
    * `clean_episode/1` — turn an episode filename like
      `"1883 - S01E01 - 1883 WEBDL-1080p.mkv"` into `"1883"` and
      extract the `SxxEyy` marker when present.

  Pure functions, no DB. The callers pair them with the raw value via
  `title=` attributes so users can still see the original filename on
  hover.
  """

  alias Streamix.Iptv.Gindex.ReleaseParser

  @sxxexx ~r/\b[Ss](?<season>\d{1,2})[ _.\-]?[Ee](?<ep>\d{1,3})\b/
  # Only treat a leading integer as an episode number if it's clearly
  # separated from what follows — "07 - Ghost" is an episode marker,
  # but "07-Ghost" (no spaces) is part of the series title.
  @leading_episode_num ~r/^\s*(\d{1,3})\s+[-._]\s+/
  @trailing_episode_num ~r/\s[-_]\s(\d{1,3})\s*$/
  @extension_tail ~r/\.(mp4|mkv|avi|mov|wmv|webm|m4v|ts)\z/i
  @fansub_prefixes ~r/^(\s*\[[^\]]+\]\s*)+/
  @bracket_groups ~r/\[[^\]]*\]/
  @paren_groups ~r/\([^)]*\)/

  # Same noise tokens ReleaseParser strips, but as a single alternation
  # so we only need one pass and never eat anything outside a word
  # boundary.
  @episode_noise ~r/\b(?:BluRay|Blu-Ray|BDRip|BRRip|BDMux|BD|WEB-?DL|WEB-?Rip|HDRip|DVDRip|HDTV|HDCAM|CAM|TS|Telesync|2160p|1080p|720p|480p|360p|4K|UHD|HDR10\+?|HDR|DV|10bit|8bit|x26[45]|H\.?26[45]|HEVC|AVC|XviD|DivX|AV1|DDP?\+?\d?[\.\+]\d|DTS(?:-?HD)?(?:-?MA)?|TrueHD|Atmos|AAC|AC3|E-AC3|FLAC|MP3|OPUS|MA|5\.1|7\.1|2\.0|DUAL|DUBLADO|DUB|LEGENDADO|LEG|MULTI|SUBS?|BRDUB|NACIONAL|PT-BR|PTBR|iNTERNAL|REPACK|PROPER|REMUX)\b/i

  @doc """
  Returns a trimmed, noise-free title. Falls back to the original
  string when the parser can't produce anything meaningful (usually an
  already-clean human-typed title).
  """
  @spec clean_title(String.t() | nil) :: String.t()
  def clean_title(nil), do: ""
  def clean_title(""), do: ""

  def clean_title(raw) when is_binary(raw) do
    %{title: parsed} = ReleaseParser.parse(raw)
    if parsed != "", do: parsed, else: raw
  end

  @doc """
  Cleans an episode line to keep it faithful to the gindex filename
  while shaving off scene noise that adds no information to the user.

  Strategy (deliberately conservative — the last round was too
  aggressive and swallowed episode numbers/release groups):

    * drop the file extension,
    * drop the leading fansub/translator `[...]` brackets (scene
      releases chain up to 3 of them: `[Ambient][MDAN] …`),
    * drop brackets/parens whose contents are *only* quality/codec
      tokens (e.g. `[720p]`, `(WEB-DL 1080p)`), keeping brackets that
      carry meaningful info untouched,
    * strip isolated quality/resolution/codec tokens
      (`1080p`, `WEBDL`, `x264`, `DTS`, …) — the canonical list lives
      in `@episode_noise`,
    * normalize `.` and `_` into spaces so dotted releases read well,
    * collapse runs of separators so we never emit `" - - "`.

  Anything else — the series name, `SxxEyy`, the episode title, the
  release group at the tail (`-NTb`, `-GLHF`) — is preserved.
  """
  @spec clean_episode(String.t() | nil) :: String.t()
  def clean_episode(nil), do: ""
  def clean_episode(""), do: ""

  def clean_episode(raw) when is_binary(raw) do
    raw
    |> String.replace(@extension_tail, "")
    |> String.replace(@fansub_prefixes, "")
    |> strip_noise_brackets()
    |> String.replace(@episode_noise, " ")
    |> String.replace(~r/[\.\_]+/, " ")
    |> String.replace(~r/(?:\s*-\s*){2,}/, " - ")
    |> collapse_spaces()
    |> strip_leading_trailing_separators()
  end

  @doc """
  Extracts the `SxxEyy` / `Ep N` label from a raw episode name, or
  `nil` if nothing matches. Kept separate from `clean_episode/1` so
  callers that want both pieces (badge + title) can read them
  independently.
  """
  @spec episode_label(String.t() | nil) :: String.t() | nil
  def episode_label(nil), do: nil
  def episode_label(""), do: nil

  def episode_label(raw) when is_binary(raw) do
    cleaned =
      raw
      |> String.replace(@extension_tail, "")
      |> String.replace(@fansub_prefixes, "")
      |> strip_noise_brackets()
      |> collapse_spaces()

    case extract_label(cleaned) do
      {nil, _} -> nil
      {label, _remainder} -> label
    end
  end

  # Only drop brackets/parens that hold *exclusively* scene noise —
  # "[720p]" goes, "[Dir's Cut]" stays, and S01E01 / episode numbers
  # living outside brackets are untouched.
  defp strip_noise_brackets(str) do
    squashed = Regex.replace(@bracket_groups, str, &maybe_drop_bracket/1)
    Regex.replace(@paren_groups, squashed, &maybe_drop_bracket/1)
  end

  defp maybe_drop_bracket(match) do
    inner = String.slice(match, 1..-2//1)
    if noise_only?(inner), do: " ", else: match
  end

  defp noise_only?(inner) do
    without_noise =
      inner
      |> String.replace(@episode_noise, " ")
      |> String.trim()

    # If stripping noise collapsed it to nothing (or to pure digits like
    # "25" which we *want* to keep outside brackets), treat as noise.
    without_noise == "" or Regex.match?(~r/^\s*\d+\s*$/, without_noise)
  end

  # --- private ---

  # Prefer S01E01 format when present — carries both season and episode
  # and is the canonical "release marker" most scrapers emit. Falls back
  # to a loose leading or trailing integer (common in anime releases
  # that omit the season tag).
  defp extract_label(str) do
    with nil <- sxxexx_label(str),
         nil <- leading_num_label(str),
         nil <- trailing_num_label(str) do
      {nil, str}
    end
  end

  defp sxxexx_label(str) do
    case Regex.named_captures(@sxxexx, str) do
      %{"season" => s, "ep" => e} ->
        {"S#{pad2(s)}E#{pad2(e)}", Regex.replace(@sxxexx, str, " ")}

      _ ->
        nil
    end
  end

  defp leading_num_label(str) do
    case Regex.run(@leading_episode_num, str, capture: :all_but_first) do
      [num] -> {"Ep #{pad2(num)}", Regex.replace(@leading_episode_num, str, "")}
      _ -> nil
    end
  end

  defp trailing_num_label(str) do
    case Regex.run(@trailing_episode_num, str, capture: :all_but_first) do
      [num] -> {"Ep #{pad2(num)}", Regex.replace(@trailing_episode_num, str, "")}
      _ -> nil
    end
  end

  defp pad2(n) when is_binary(n), do: String.pad_leading(n, 2, "0")

  defp collapse_spaces(s), do: s |> String.replace(~r/\s+/, " ") |> String.trim()

  defp strip_leading_trailing_separators(s) do
    s |> String.replace(~r/^[\s\-–—_\.]+|[\s\-–—_\.]+$/, "") |> String.trim()
  end
end
