defmodule Streamix.Iptv.Gindex.ReleaseParser do
  @moduledoc """
  Cleans gindex folder/file names down to a `{title, year}` pair
  suitable for a TMDB search query.

  The Google Drive catalog gives us strings like
  `"A Era do Gelo 1 2002 1080p BluRay x264 Dual"` — readable to a human,
  but TMDB's search endpoint cannot match those verbatim. We extract the
  year using the same lookahead trick Radarr uses (digits that look like
  a year, not a resolution or codec), treat everything before the year
  as the title, then strip release-scene noise from it.

  Falls back to `{cleaned_string, nil}` when no four-digit year is found.
  """

  # Year 1800-2099, but NOT followed by "p", "i", "x" (resolution/codec
  # hints like 1080p, 720i, x264) or another digit (avoids catching the
  # middle of a larger number). Radarr uses the same shape.
  @year_regex ~r/(?<year>(18|19|20)\d{2})(?![pixPIX\d])/

  # Strip markers that definitely aren't part of the human-readable title.
  # Order matters: the more specific tokens (multi-word, dotted) first.
  @noise_patterns [
    # Release sources
    ~r/\b(BluRay|Blu-Ray|BDRip|BRRip|BDMux|WEB-?DL|WEB-?Rip|HDRip|DVDRip|HDTV|HDCAM|CAM|TS|Telesync)\b/i,
    # Resolution & HDR
    ~r/\b(2160p|1080p|720p|480p|360p|4K|UHD|HDR10\+?|HDR|Dolby\.?Vision|DV)\b/i,
    # Video codecs
    ~r/\b(x26[45]|H\.?26[45]|HEVC|AVC|XviD|DivX|AV1)\b/i,
    # Audio codecs (including the "5.1" / "7.1" / "2.0" channel hints)
    ~r/\b(DDP?\+?\d?[\.\+]\d|DTS(-?HD)?(-?MA)?|TrueHD|Atmos|AAC|AC3|E-AC3|FLAC|MP3|OPUS)\b/i,
    ~r/\b(5\.1|7\.1|2\.0)\b/,
    # Language / subtitle tags
    ~r/\b(DUAL|DUBLADO|DUB|LEGENDADO|LEG|MULTI|SUBS?|BRDUB|NACIONAL|PT-BR|PTBR|iNTERNAL|REPACK|PROPER|REMUX)\b/i,
    # Extension tail
    ~r/\.(mp4|mkv|avi|mov|wmv|webm|m4v|ts)\z/i
  ]

  # Final pass: collapse separators that the noise stripping left behind.
  @separator_collapse ~r/[\.\_\-]+/

  @type parsed :: %{title: String.t(), year: integer() | nil}

  @doc """
  Parses a raw folder/file name into `{title, year}`.

      iex> parse("A Era do Gelo 1 2002 1080p BluRay x264 Dual")
      %{title: "A Era do Gelo 1", year: 2002}

      iex> parse("A Bela Adormecida (1959) [1080p BluRay DUAL]")
      %{title: "A Bela Adormecida", year: 1959}

      iex> parse("13 Reasons Why")
      %{title: "13 Reasons Why", year: nil}
  """
  @spec parse(String.t() | nil) :: parsed()
  def parse(nil), do: %{title: "", year: nil}
  def parse(""), do: %{title: "", year: nil}

  def parse(raw) when is_binary(raw) do
    {pre_year, year} = split_on_year(raw)

    title =
      pre_year
      |> strip_noise()
      |> strip_brackets()
      |> normalize_separators()
      |> String.trim()

    %{title: title, year: year}
  end

  # --- private ---

  defp split_on_year(raw) do
    case Regex.run(@year_regex, raw, return: :index, capture: :first) do
      [{start, len}] ->
        year = raw |> binary_part(start, len) |> String.to_integer()
        pre = binary_part(raw, 0, start)
        {pre, year}

      _ ->
        {raw, nil}
    end
  end

  defp strip_noise(str) do
    Enum.reduce(@noise_patterns, str, fn pattern, acc ->
      Regex.replace(pattern, acc, " ")
    end)
  end

  # Whole-pair brackets holding only noise are already gone, but a
  # dangling opener/closer can linger after trimming the year. Wipe them.
  defp strip_brackets(str) do
    str
    |> String.replace(~r/[\[\]\(\)\{\}]/, " ")
  end

  defp normalize_separators(str) do
    str
    |> String.replace(@separator_collapse, " ")
    |> String.replace(~r/\s+/, " ")
  end
end
