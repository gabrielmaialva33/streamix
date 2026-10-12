defmodule Streamix.Torrent.Sources.ReleaseInfo do
  @moduledoc """
  Parses the title strings BR torrent sites use into structured release
  metadata: clean title, year, quality tier, audio track and quality
  flags.

  BR torrent posts title releases like
  `"Vingadores: Ultimato (2019) Torrent - BluRay 1080p Dual Áudio"`.
  We extract a TMDB-searchable `{title, year}` plus the `quality` and
  `audio_track` (dublado / dual / legendado) so the catalog can badge
  and rank them and the player can offer the right audio.

  Some releases are not what their audio label suggests. A fan-made or
  otherwise unofficial dub ("Dublado Não Oficial", "Fan Dub") and a
  camera or telesync capture ("CAM", "HDCAM", "TS") are kept, but they
  carry `flags` (`"unofficial_dub"`, `"cam"`) so ranking and labels can
  push them behind clean releases. An unofficial dub is never reported as
  `"dublado"` or `"dual"`: its `audio_track` is `"dublado_nao_oficial"`.

  Kept inside the Torrent context (not reusing `Gindex.ReleaseParser`)
  to respect context boundaries; the small regex overlap is acceptable.
  """

  @paren_year ~r/\(\s*(?<year>(?:19|20)\d{2})\s*\)/u
  @bare_year ~r/(?<![\p{L}\p{N}])(?<year>(?:19|20)\d{2})(?![\p{N}pPiIxX])/u

  @quality_patterns [
    {~r/\b(2160p|4k|uhd)\b/iu, "2160p"},
    {~r/\b1080p\b/iu, "1080p"},
    {~r/\b720p\b/iu, "720p"},
    {~r/\b480p\b/iu, "480p"}
  ]

  # A fan-made dub announces itself as "Fan Dub" or as an explicitly
  # unofficial dub ("Dublado Não Oficial", "Dublagem Não Oficial",
  # "PT-BR-NAO-OFICIAL"). "Não oficial" alone is not enough: it has to sit
  # next to a dub/audio word so an unofficial *subtitle* is not flagged.
  @unofficial_dub ~r/fan[\s._-]*dub|(?:dublad[oa]|dublagem|dub|pt[\s._-]*br|[áa]udio)[\s._()\-]*n[ãa]o[\s._-]*oficial|dublagem[\s._-]*amadora/iu

  # Camera and telesync captures. Lower-case "ts" is too common inside
  # scene names to trust, so the bare token only counts in upper case.
  @cam ~r/\b(?:hd[\s._-]?)?cam(?:[\s._-]?rip)?\b|\btele[\s._-]?sync\b|\bts[\s._-]?cam\b|\bhd[\s._-]?ts\b/iu
  @cam_upper ~r/(?<![\p{L}\p{N}])TS(?:[\s._-]?RIP)?(?![\p{L}\p{N}])/u

  # Posts that describe a season, a miniseries or a multi-movie bundle are
  # not one movie and must not be ingested as one.
  @series ~r/\b\d+\s*(?:ª|a|º|o)?[\s._-]*temporada\b|\btemporadas?\b|\bminiss[ée]rie\b|\bs\d{1,2}[\s._-]?e\d{1,3}\b|\bseason\b/iu
  @bundle ~r/\blist[ãa]o\b|\btrilogia\b|\bduologia\b|\bquadrilogia\b|\bcole[çc][ãa]o\b|todos[\s._-]+os[\s._-]+filmes|\bpack\b/iu

  # Noise stripped from the title once year/quality/audio are pulled out.
  @noise ~r/\b(torrent|baixar|download|bluray|blu-?ray|bdrip|brrip|web-?dl|web-?rip|webrip|hdrip|dvdrip|hdtv|hdcam|camrip|2160p|1080p|720p|480p|4k|uhd|full\s*hd|hdr10?\+?|x26[45]|h\.?26[45]|hevc|av1|xvid|dual|tri|dublado|dublada|dublagem|dub|legendado|legendada|leg|nacional|multi|5\.1|7\.1|2\.0|dts|ac3|aac|ddp?\+?\d|[áa]udio|mkv|mp4)\b/iu

  # Words that may follow a " - " separator without being part of the
  # title ("Little Town - Legendado e Dublado Não Oficial").
  @segment_noise ~w(e não nao oficial fan cam ts cinema filme completo versão versao sem legenda
                    legendas download baixar torrent)

  @type t :: %{
          title: String.t(),
          year: integer() | nil,
          quality: String.t() | nil,
          audio_track: String.t() | nil,
          flags: [String.t()]
        }

  @type magnet_release :: %{
          quality: String.t() | nil,
          audio_track: String.t() | nil,
          flags: [String.t()]
        }

  @doc """
  Parses a raw release title.

      iex> parse("Duna (2021) Torrent - BluRay 1080p Dual Áudio")
      %{title: "Duna", year: 2021, quality: "1080p", audio_track: "dual", flags: []}
  """
  @spec parse(String.t() | nil) :: t()
  def parse(nil), do: empty()
  def parse(""), do: empty()

  def parse(raw) when is_binary(raw) do
    flags = extract_flags(raw)

    %{
      title: extract_title(raw),
      year: extract_year(raw),
      quality: extract_quality(raw),
      audio_track: labelled_audio(extract_audio(raw), "unofficial_dub" in flags),
      flags: flags
    }
  end

  @doc """
  Resolves the release attributes of one magnet inside a post.

  A post often lists several files with different audio ("DUAL ÁUDIO 1080p"
  next to "LEGENDADO 2160p"), so the magnet's own text (its label and its
  `dn=` display name) wins, then the section heading it sits under, then the
  post title.
  """
  @spec for_magnet(String.t() | nil, String.t() | nil, String.t() | nil) :: magnet_release()
  def for_magnet(post_title, local_text, section_text) do
    # Most specific first: the file's own text, its section, the post.
    texts = Enum.map([local_text, section_text, post_title], &(&1 || ""))
    [local | inherited] = texts

    audio = Enum.find_value(texts, &extract_audio/1)

    # A dub that the file itself calls unofficial is unofficial. An
    # "unofficial dub" post only taints the files that actually are dubs, not
    # its subtitled ones.
    unofficial? =
      unofficial_dub?(local) or
        (audio in ["dual", "dublado"] and Enum.any?(inherited, &unofficial_dub?/1))

    %{
      quality: Enum.find_value(texts, &extract_quality/1),
      audio_track: labelled_audio(audio, unofficial?),
      flags: flags(unofficial?, Enum.any?(texts, &cam?/1))
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

  This is the raw flavor; `parse/1` and `for_magnet/3` relabel an
  unofficial dub as `"dublado_nao_oficial"`.
  """
  @spec extract_audio(String.t()) :: String.t() | nil
  def extract_audio(raw) do
    down = String.downcase(raw)

    cond do
      Regex.match?(~r/\bdual\b|\b(?:tri|multi)[\s._-]?[áa]udio\b/u, down) -> "dual"
      Regex.match?(~r/\bdublad[oa]\b|\bdublagem\b|\bdub\b|\bnacional\b/u, down) -> "dublado"
      Regex.match?(~r/\blegendad[oa]\b|\bleg\b|\bsub\b/u, down) -> "legendado"
      true -> nil
    end
  end

  @doc ~s|Release flags ("unofficial_dub", "cam") found in a release string.|
  @spec extract_flags(String.t()) :: [String.t()]
  def extract_flags(raw) when is_binary(raw) do
    flags(unofficial_dub?(raw) and extract_audio(raw) in ["dual", "dublado"], cam?(raw))
  end

  @doc "Whether the string advertises a fan-made / unofficial dub."
  @spec unofficial_dub?(String.t()) :: boolean()
  def unofficial_dub?(raw) when is_binary(raw), do: Regex.match?(@unofficial_dub, raw)

  @doc "Whether the string advertises a camera or telesync capture."
  @spec cam?(String.t()) :: boolean()
  def cam?(raw) when is_binary(raw), do: Regex.match?(@cam, raw) or Regex.match?(@cam_upper, raw)

  @doc "Whether a post title/URL describes a TV season or miniseries."
  @spec series?(String.t()) :: boolean()
  def series?(raw) when is_binary(raw), do: Regex.match?(@series, normalize_separators(raw))

  @doc "Whether a post title/URL describes a multi-movie bundle (trilogy, collection, …)."
  @spec bundle?(String.t()) :: boolean()
  def bundle?(raw) when is_binary(raw), do: Regex.match?(@bundle, normalize_separators(raw))

  @doc """
  Four-digit release year, or nil. A year in parentheses wins; otherwise
  the last bare year, so `"Blade Runner 2049 (2017)"` is 2017.
  """
  @spec extract_year(String.t()) :: integer() | nil
  def extract_year(raw) do
    case Regex.named_captures(@paren_year, raw) do
      %{"year" => year} ->
        String.to_integer(year)

      nil ->
        case Regex.scan(@bare_year, raw, capture: ["year"]) do
          [] -> nil
          matches -> matches |> List.last() |> hd() |> String.to_integer()
        end
    end
  end

  @doc "Human title with year/quality/audio/flag noise stripped."
  @spec extract_title(String.t()) :: String.t()
  def extract_title(raw) do
    raw = String.replace(raw, ~r/^\s*(?:baixar|download)\s+/iu, "")

    # A title that is itself a year ("1917") would be cut away entirely.
    case raw |> cut_at_release_marker() |> clean_title() do
      "" -> clean_title(raw)
      title -> title
    end
  end

  defp clean_title(raw) do
    raw
    |> drop_trailing_noise_segments()
    |> String.replace(@unofficial_dub, " ")
    |> String.replace(~r/[\(\)\[\]]/u, " ")
    |> String.replace(@noise, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.trim_trailing("-")
    |> String.trim_trailing("|")
    |> String.trim()
  end

  # The title ends where the release description starts: the word
  # "Torrent", a parenthesised year or a " | " separator, whichever comes
  # first. Without any of them the last bare year marks it.
  defp cut_at_release_marker(raw) do
    markers =
      [~r/\btorrent\b/iu, @paren_year, ~r/\s\|\s/u]
      |> Enum.flat_map(fn re ->
        case Regex.run(re, raw, return: :index) do
          [{start, _len} | _] -> [start]
          _ -> []
        end
      end)

    case markers do
      [] -> cut_at_last_bare_year(raw)
      starts -> binary_part(raw, 0, Enum.min(starts))
    end
  end

  defp cut_at_last_bare_year(raw) do
    case Regex.scan(@bare_year, raw, return: :index) do
      [] ->
        raw

      matches ->
        [{start, _len} | _captures] = List.last(matches)
        binary_part(raw, 0, start)
    end
  end

  defp drop_trailing_noise_segments(title) do
    title
    |> String.split(~r/\s+[-–—]\s+/u)
    |> Enum.reverse()
    |> Enum.drop_while(&noise_segment?/1)
    |> Enum.reverse()
    |> Enum.join(" - ")
  end

  defp noise_segment?(segment) do
    stripped =
      segment
      |> String.replace(@unofficial_dub, " ")
      |> String.replace(@noise, " ")
      |> String.replace(~r/[\(\)\[\]]/u, " ")
      |> String.downcase()
      |> String.split(~r/\s+/u, trim: true)
      |> Enum.reject(&(&1 in @segment_noise))

    stripped == []
  end

  defp normalize_separators(raw), do: String.replace(raw, ~r/[._\/-]+/u, " ")

  defp labelled_audio(audio, true) when audio in ["dual", "dublado"], do: "dublado_nao_oficial"
  defp labelled_audio(audio, _unofficial?), do: audio

  defp flags(unofficial?, cam?) do
    Enum.flat_map([{unofficial?, "unofficial_dub"}, {cam?, "cam"}], fn
      {true, flag} -> [flag]
      {false, _flag} -> []
    end)
  end

  defp empty, do: %{title: "", year: nil, quality: nil, audio_track: nil, flags: []}
end
