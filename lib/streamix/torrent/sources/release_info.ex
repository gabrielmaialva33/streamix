defmodule Streamix.Torrent.Sources.ReleaseInfo do
  @moduledoc """
  Parses the title strings BR torrent sites use into structured release
  metadata: clean title, year, quality tier and audio track.

  BR WordPress torrent posts title releases like
  `"Vingadores: Ultimato (2019) Torrent - BluRay 1080p Dual Áudio"`.
  We extract a TMDB-searchable `{title, year}` plus the `quality` and
  `audio_track` (dublado / dual / legendado) so the catalog can badge
  and rank them and the player can offer the right audio.

  Kept inside the Torrent context (not reusing `Gindex.ReleaseParser`)
  to respect context boundaries; the small regex overlap is acceptable.
  """

  @year_regex ~r/\b(?<year>(19|20)\d{2})\b(?![pixPIX])/

  @quality_patterns [
    {~r/\b(2160p|4k|uhd)\b/i, "2160p"},
    {~r/\b1080p\b/i, "1080p"},
    {~r/\b720p\b/i, "720p"},
    {~r/\b480p\b/i, "480p"}
  ]

  # Noise stripped from the title once year/quality/audio are pulled out.
  @noise ~r/\b(torrent|baixar|download|bluray|blu-?ray|bdrip|brrip|web-?dl|web-?rip|hdrip|dvdrip|hdtv|hdcam|2160p|1080p|720p|480p|4k|uhd|hdr10?\+?|x26[45]|h\.?26[45]|hevc|av1|xvid|dual|dublado|dub|legendado|leg|nacional|multi|5\.1|7\.1|2\.0|dts|ac3|aac|ddp?\+?\d)\b/i

  @type t :: %{
          title: String.t(),
          year: integer() | nil,
          quality: String.t() | nil,
          audio_track: String.t() | nil
        }

  @doc """
  Parses a raw release title.

      iex> parse("Duna (2021) Torrent - BluRay 1080p Dual Áudio")
      %{title: "Duna", year: 2021, quality: "1080p", audio_track: "dual"}
  """
  @spec parse(String.t() | nil) :: t()
  def parse(nil), do: empty()
  def parse(""), do: empty()

  def parse(raw) when is_binary(raw) do
    %{
      title: extract_title(raw),
      year: extract_year(raw),
      quality: extract_quality(raw),
      audio_track: extract_audio(raw)
    }
  end

  @doc "Quality tier from a release string, or nil."
  @spec extract_quality(String.t()) :: String.t() | nil
  def extract_quality(raw) do
    Enum.find_value(@quality_patterns, fn {re, tier} ->
      if Regex.match?(re, raw), do: tier
    end)
  end

  @doc """
  Audio track flavor: `"dublado"`, `"dual"`, `"legendado"`, or `nil`
  (unknown / likely original audio). `dual` wins over `dublado` when both
  appear, since dual-audio releases include the dub.
  """
  @spec extract_audio(String.t()) :: String.t() | nil
  def extract_audio(raw) do
    down = String.downcase(raw)

    cond do
      String.contains?(down, "dual") -> "dual"
      Regex.match?(~r/\bdublad[oa]\b|\bdub\b|\bnacional\b/u, down) -> "dublado"
      Regex.match?(~r/\blegendad[oa]\b|\bleg\b|\bsub\b/u, down) -> "legendado"
      true -> nil
    end
  end

  @doc "Four-digit release year, or nil."
  @spec extract_year(String.t()) :: integer() | nil
  def extract_year(raw) do
    case Regex.named_captures(@year_regex, raw) do
      %{"year" => year} -> String.to_integer(year)
      _ -> nil
    end
  end

  @doc "Human title with year/quality/scene noise stripped."
  @spec extract_title(String.t()) :: String.t()
  def extract_title(raw) do
    raw
    |> String.split(~r/\btorrent\b/i, parts: 2)
    |> List.first()
    |> String.replace(@year_regex, "")
    |> String.replace(~r/[\(\)\[\]]/, " ")
    |> String.replace(@noise, " ")
    |> String.replace(~r/\s*-\s*$/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.trim_trailing("-")
    |> String.trim()
  end

  defp empty, do: %{title: "", year: nil, quality: nil, audio_track: nil}
end
