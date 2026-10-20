defmodule StreamixWeb.Content.DisplayTitle do
  @moduledoc """
  The title a viewer reads, from the name a provider stored.

  Provider names carry release noise ("Armadilha [LEG]", "22 de Julho 4K
  [Hybrid]", "ICE 2019 [720p]", "[Reel] A Noiva…", "Dawsons.Creek.S01E01…")
  that belongs in badges, not in the title. Cleaning is conservative so a
  real title survives: noise is only taken from the END of the name or from
  brackets, and a bare year at the end goes only when release noise followed
  it ("Blade Runner 2049" and "1917" stay). The stored name is never changed.
  """

  # Release noise that may end a name. Matched case-insensitively as whole
  # tokens, repeatedly, from the end.
  @trailing_tokens ~w(
    4k uhd fhd hd sd hdr hdr10 dv dolby vision 2160p 1080p 720p 480p hybrid
    web-dl webdl webrip web bluray bdrip brrip dvdrip hdtv remux imax
    x264 x265 h264 h265 hevc avc aac ac3 eac3 dts atmos 5.1 2.0
    dual audio dublado dublada legendado legendada dub leg nacional multi
  )

  # Bracketed language or shelf tags anywhere in the name: [LEG], [L], [D],
  # (Dual), [Reel]. They say nothing about a year next to them.
  @bracketed_tags ~r/\s*[\[(](?:leg|l|d|dub|dual|dual audio|dublado|legendado|nacional|reel|reels)[\])]\s*/iu

  # Bracketed release tags: [Hybrid], [720p], [BluRay]… A year right before them
  # is the release's, as with trailing noise.
  @bracketed_release ~r/\s*[\[(](?:hybrid|hdr|4k|uhd|fhd|hd|\d{3,4}p|web-?dl|webrip|bluray|remux)[\])]\s*/iu

  @year_suffix ~r/\s*\((?:19|20)\d{2}\)\s*$/u
  @bare_year_suffix ~r/\s+(?:19|20)\d{2}$/u
  @year_then_noise ~r/^(.+?)\s*\((?:19|20)\d{2}\)\s+(\S+)/u
  @episode_prefix ~r/^(?:.+?\s[-–]\s)?s\d{1,2}\s?e\d{1,4}\s[-–]\s+/iu
  @channel_prefix ~r/^\s*\(\d{1,3}\)\s*/u

  @doc """
  The clean title of a catalog item (map or struct with `:title`/`:name`) or of
  a raw string. Falls back to the raw text when cleaning would leave nothing.
  """
  @spec title(map() | String.t() | nil) :: String.t()
  def title(%{} = item), do: item |> raw() |> clean()
  def title(text), do: clean(text)

  @doc "Cleans one raw name."
  @spec clean(String.t() | nil) :: String.t()
  def clean(nil), do: ""

  def clean(text) when is_binary(text) do
    raw = String.trim(text)

    untagged = raw |> undot() |> String.replace(@bracketed_tags, " ")
    released = String.replace(untagged, @bracketed_release, " ")
    cleaned = released |> cut_after_year() |> strip(released != untagged, false) |> collapse()

    if cleaned == "", do: raw, else: cleaned
  end

  @doc """
  The title of an episode without the series name and SxxEyy code that some
  providers prepend ("Dawson's Creek - S01E01 - Piloto" → "Piloto").
  """
  @spec episode(String.t() | nil) :: String.t()
  def episode(text) do
    cleaned = clean(text)
    stripped = cleaned |> String.replace(@episode_prefix, "") |> String.trim()
    if stripped == "", do: cleaned, else: stripped
  end

  @doc """
  A live channel name without the provider's list number and emoji
  ("(01) ⏰ 13:45 • Fenerbahçe x Slavia" → "13:45 • Fenerbahçe x Slavia").
  """
  @spec channel(String.t() | nil) :: String.t()
  def channel(nil), do: ""

  def channel(text) when is_binary(text) do
    cleaned =
      text
      |> String.replace(@channel_prefix, "")
      |> String.replace(~r/[\x{2300}-\x{23FF}\x{2600}-\x{27BF}\x{1F300}-\x{1FAFF}\x{FE0F}]/u, "")
      |> collapse()

    if cleaned == "", do: String.trim(text), else: cleaned
  end

  defp raw(item), do: Map.get(item, :title) || Map.get(item, :name) || ""

  # "Dawsons.Creek.S01E01.Pilot" is a file name: dots stand for spaces.
  defp undot(text) do
    if not String.contains?(text, " ") and length(String.split(text, ".")) > 2,
      do: String.replace(text, ".", " "),
      else: text
  end

  # "2067 (2020) 1080p BluRay DD+5 1 x264-DUAL": a "(year)" followed by
  # release noise ends the title, whatever the noise looks like after it.
  defp cut_after_year(text) do
    case Regex.run(@year_then_noise, text) do
      [_, title, first] -> if token?(first), do: title, else: text
      nil -> text
    end
  end

  # Trailing noise, "(2025)" years (the year is a badge) and, once release
  # noise went, one bare year, until nothing changes: "Insurreição 1998
  # Dublado 1080p" needs the tokens gone before its year can go, and in
  # "Blade Runner 2049 2017 [WEB-DL]" only 2017 is the year.
  defp strip(text, noisy?, year_taken?) do
    {stripped, removed?} = strip_tokens(text, false)
    noisy? = noisy? or removed?
    unyeared = String.replace(stripped, @year_suffix, "")
    year_taken? = year_taken? or unyeared != stripped

    {stripped, year_taken?} =
      if noisy? and not year_taken? and Regex.match?(@bare_year_suffix, unyeared),
        do: {String.replace(unyeared, @bare_year_suffix, ""), true},
        else: {unyeared, year_taken?}

    if stripped == text, do: text, else: strip(stripped, noisy?, year_taken?)
  end

  defp strip_tokens(text, removed?) do
    trimmed = String.replace(text, ~r/[\s\-–|+]+$/u, "")

    case String.split(trimmed, ~r/\s+/u) do
      [_only] ->
        {trimmed, removed?}

      words ->
        if words |> List.last() |> token?() do
          words |> Enum.drop(-1) |> Enum.join(" ") |> strip_tokens(true)
        else
          {trimmed, removed?}
        end
    end
  end

  defp token?(word), do: (word |> String.downcase() |> String.trim("[]()")) in @trailing_tokens

  defp collapse(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()
end
