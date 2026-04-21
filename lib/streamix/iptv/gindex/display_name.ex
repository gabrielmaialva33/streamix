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
  Cleans an episode line. Returns `{label, episode_title}` where
  `label` is the `SxxEyy` marker (or `"Ep N"` when we only have a
  loose number) and `episode_title` is the human-readable tail with
  release noise removed.

  Examples:

      iex> clean_episode("1883 - S01E01 - 1883 WEBDL-1080p.mkv")
      {"S01E01", "1883"}

      iex> clean_episode("[Ambient][MDAN] 07-Ghost - 01 [720p].mkv")
      {"Ep 01", "07-Ghost"}
  """
  @spec clean_episode(String.t() | nil) :: {String.t() | nil, String.t()}
  def clean_episode(nil), do: {nil, ""}
  def clean_episode(""), do: {nil, ""}

  def clean_episode(raw) when is_binary(raw) do
    # Strip the scaffolding (extension, fansub/quality brackets) first
    # so `extract_label/1` sees a clean string — otherwise a trailing
    # `[720p]` would block the "Ep N" match on anime releases.
    cleaned =
      raw
      |> String.replace(@extension_tail, "")
      |> String.replace(@fansub_prefixes, "")
      |> String.replace(@bracket_groups, " ")
      |> String.replace(@paren_groups, " ")
      |> collapse_spaces()

    {label, remainder} = extract_label(cleaned)

    title =
      remainder
      |> String.replace(@episode_noise, " ")
      |> String.replace(~r/[\.\_]+/, " ")
      |> String.replace(~r/\s*[-–—]\s*/, " - ")
      # Collapse runs of consecutive separator tokens: "1883 - - 1883" → "1883 - 1883"
      |> String.replace(~r/(?:\s*-\s*){2,}/, " - ")
      |> collapse_spaces()
      |> strip_leading_trailing_separators()

    {label, title}
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
