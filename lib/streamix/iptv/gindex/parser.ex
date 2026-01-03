defmodule Streamix.Iptv.Gindex.Parser do
  @moduledoc """
  Parser for GIndex file and folder names.

  Extracts metadata from naming conventions commonly used in media files.

  ## Folder patterns:
  - "Nome PT [Nome Original] (Ano)" -> Movie folder
  - "Nome da Série (Ano)" -> Series folder

  ## File patterns:
  - "Nome.Ano.Qualidade.Fonte.Codec-Release.ext" -> Movie file
  - "Nome.S01E01.Qualidade.Fonte.Codec-Release.ext" -> Episode file
  """

  @video_extensions ~w(mkv mp4 avi mov wmv flv webm m4v)
  @quality_patterns ~w(2160p 1080p 720p 480p 4K UHD HDR)
  @source_patterns ~w(AMZN NF DSNP HMAX HBO ATVP PMTP WEB-DL WEBRip BluRay BDRip HDRip DVDRip)

  @doc """
  Parses a movie or series folder name.

  ## Examples

      iex> Parser.parse_movie_folder("A Hora do Mal [Weapons] (2025)")
      %{name: "A Hora do Mal", original_name: "Weapons", year: 2025}

      iex> Parser.parse_movie_folder("Avatar (2009)")
      %{name: "Avatar", original_name: nil, year: 2009}

      iex> Parser.parse_movie_folder("13 Reasons Why (2017)")
      %{name: "13 Reasons Why", original_name: nil, year: 2017}
  """
  def parse_movie_folder(nil), do: %{name: nil, original_name: nil, year: nil}

  def parse_movie_folder(folder_name) when is_binary(folder_name) do
    folder_name = String.trim(folder_name)

    # Pattern: "Nome PT [Nome Original] (Ano)"
    case Regex.run(~r/^(.+?)\s*\[(.+?)\]\s*\((\d{4})\)$/, folder_name) do
      [_, name_pt, original, year] ->
        %{
          name: String.trim(name_pt),
          original_name: String.trim(original),
          year: String.to_integer(year)
        }

      nil ->
        # Pattern: "Nome (Ano)"
        case Regex.run(~r/^(.+?)\s*\((\d{4})\)$/, folder_name) do
          [_, name, year] ->
            %{
              name: String.trim(name),
              original_name: nil,
              year: String.to_integer(year)
            }

          nil ->
            # Fallback: just the name
            %{
              name: folder_name,
              original_name: nil,
              year: nil
            }
        end
    end
  end

  @doc """
  Alias for parse_movie_folder/1 - same pattern applies to series folders.

  ## Examples

      iex> Parser.parse_series_folder("A Casa do Dragão [House of the Dragon] (2022)")
      %{name: "A Casa do Dragão", original_name: "House of the Dragon", year: 2022}

      iex> Parser.parse_series_folder("1883")
      %{name: "1883", original_name: nil, year: nil}
  """
  def parse_series_folder(folder_name), do: parse_movie_folder(folder_name)

  @doc """
  Parses an anime folder name.

  Anime folders typically don't have years, but may have:
  - Season indicators: "2nd Season", "Season 2", or just "2"
  - Type indicators: "(TV)", "(ONA)", "(OVA)"
  - Original names in brackets: "[Original Name]"

  ## Examples

      iex> Parser.parse_anime_folder("86 - Eighty Six")
      %{name: "86 - Eighty Six", original_name: nil, year: nil, season_indicator: nil}

      iex> Parser.parse_anime_folder("Ajin 2nd Season")
      %{name: "Ajin", original_name: nil, year: nil, season_indicator: "2nd Season"}

      iex> Parser.parse_anime_folder("Aggressive Retsuko (ONA)")
      %{name: "Aggressive Retsuko", original_name: nil, year: nil, type: "ONA"}

      iex> Parser.parse_anime_folder("30-sai made Doutei [Cherry Magic!]")
      %{name: "30-sai made Doutei", original_name: "Cherry Magic!", year: nil}
  """
  def parse_anime_folder(nil),
    do: %{name: nil, original_name: nil, year: nil, type: nil, season_indicator: nil}

  def parse_anime_folder(folder_name) when is_binary(folder_name) do
    folder_name = String.trim(folder_name)

    {name, original_name} = extract_original_name(folder_name)
    {name, year} = extract_year_from_name(name)
    {name, type} = extract_anime_type(name)
    {name, season_indicator} = extract_season_indicator(name)

    %{
      name: name,
      original_name: original_name,
      year: year,
      type: type,
      season_indicator: season_indicator
    }
  end

  defp extract_original_name(folder_name) do
    case Regex.run(~r/^(.+?)\s*\[(.+?)\]/, folder_name) do
      [_, n, orig] -> {String.trim(n), String.trim(orig)}
      nil -> {folder_name, nil}
    end
  end

  defp extract_year_from_name(name) do
    case Regex.run(~r/^(.+?)\s*\((\d{4})\)$/, name) do
      [_, n, y] -> {String.trim(n), String.to_integer(y)}
      nil -> {name, nil}
    end
  end

  defp extract_anime_type(name) do
    case Regex.run(~r/^(.+?)\s*\((ONA|OVA|TV|Movie)\)$/i, name) do
      [_, n, t] -> {String.trim(n), String.upcase(t)}
      nil -> {name, nil}
    end
  end

  @anime_season_patterns [
    {~r/^(.+?)\s+(\d+)$/, :simple},
    {~r/^(.+?)\s+((2nd|3rd|4th|5th)\s+Season)$/i, :ordinal},
    {~r/^(.+?)\s+(Season\s+\d+)$/i, :simple},
    {~r/^(.+?)\s+(Part\s+\d+)$/i, :simple}
  ]

  defp extract_season_indicator(name) do
    Enum.find_value(@anime_season_patterns, {name, nil}, fn {pattern, type} ->
      case Regex.run(pattern, name) do
        nil -> nil
        match -> extract_season_match(match, type)
      end
    end)
  end

  defp extract_season_match([_, n, s], :simple), do: {String.trim(n), s}
  defp extract_season_match([_, n, s, _], :ordinal), do: {String.trim(n), s}

  @doc """
  Parses an anime episode filename.

  Anime episodes follow the pattern: `[Group] Name - NNN [Quality][Audio].ext`

  ## Examples

      iex> Parser.parse_anime_episode("[Anitsu] 86 Eighty Six - 01 [BD 1080p][Dual Áudio].mkv")
      %{episode: 1, group: "Anitsu", quality: "BD 1080p", extension: "mkv"}

      iex> Parser.parse_anime_episode("[HBO Max] Naruto - 001 [WEB-DL 1080p][Dual Áudio].mkv")
      %{episode: 1, group: "HBO Max", quality: "WEB-DL 1080p", extension: "mkv"}
  """
  def parse_anime_episode(nil),
    do: %{episode: nil, group: nil, quality: nil, extension: nil, is_dual: false}

  def parse_anime_episode(filename) when is_binary(filename) do
    filename = String.trim(filename)
    {name_without_ext, extension} = split_extension(filename)

    # Pattern: [Group] Name - NNN [Quality][Audio]
    # Extract episode number: - NNN [
    episode =
      case Regex.run(~r/-\s*(\d{1,3})\s*\[/, name_without_ext) do
        [_, ep] ->
          String.to_integer(ep)

        nil ->
          # Try alternate patterns: - NNN. or - NNN at end
          case Regex.run(~r/-\s*(\d{1,3})(?:\.|$)/, name_without_ext) do
            [_, ep] -> String.to_integer(ep)
            nil -> nil
          end
      end

    # Extract group: [Group]
    group =
      case Regex.run(~r/^\[([^\]]+)\]/, name_without_ext) do
        [_, g] -> g
        nil -> nil
      end

    # Extract quality info from brackets after episode number
    quality =
      case Regex.run(~r/-\s*\d{1,3}\s*\[([^\]]+)\]/, name_without_ext) do
        [_, q] -> q
        nil -> nil
      end

    # Check for dual audio
    is_dual = String.contains?(String.downcase(name_without_ext), "dual")

    %{
      episode: episode,
      group: group,
      quality: quality,
      extension: extension,
      is_dual_audio: is_dual,
      raw_filename: filename
    }
  end

  @doc """
  Parses a release folder name to extract quality and audio info.

  Used to rank releases and pick the best one.

  ## Examples

      iex> Parser.parse_release_folder("Anitsu (Dual Áudio) - BD 1080p HEVC")
      %{group: "Anitsu", is_dual: true, quality: "1080p", source: "BD", codec: "HEVC", score: 100}

      iex> Parser.parse_release_folder("Dual Áudio (Eternal) - BD 1080p")
      %{group: "Eternal", is_dual: true, quality: "1080p", source: "BD", codec: nil, score: 95}
  """
  @quality_patterns [
    {["2160P", "4K"], "2160p"},
    {["1080P"], "1080p"},
    {["720P"], "720p"},
    {["480P"], "480p"}
  ]

  @source_patterns [
    {["BDREMUX", "REMUX"], "BDRemux"},
    {["BD ", "BLURAY"], "BD"},
    {["WEB-DL"], "WEB-DL"},
    {["WEBRIP"], "WEBRip"},
    {["HDTV"], "HDTV"}
  ]

  @codec_patterns [
    {["HEVC", "X265", "H.265"], "HEVC"},
    {["X264", "H.264"], "H.264"}
  ]

  @quality_scores %{"2160p" => 40, "1080p" => 30, "720p" => 20, "480p" => 10}
  @source_scores %{"BDRemux" => 25, "BD" => 20, "WEB-DL" => 15, "WEBRip" => 10, "HDTV" => 5}
  @codec_scores %{"HEVC" => 10, "H.264" => 5}

  def parse_release_folder(nil),
    do: %{
      group: nil,
      is_dual: false,
      quality: nil,
      source: nil,
      codec: nil,
      score: 0,
      raw_name: nil
    }

  def parse_release_folder(folder_name) when is_binary(folder_name) do
    folder_name = String.trim(folder_name)
    upcase_name = String.upcase(folder_name)

    is_dual = String.contains?(upcase_name, "DUAL")
    quality = find_pattern_match(upcase_name, @quality_patterns)
    source = find_pattern_match(upcase_name, @source_patterns)
    codec = find_pattern_match(upcase_name, @codec_patterns)
    group = extract_anime_release_group(folder_name)
    score = calculate_release_score(quality, source, codec, is_dual)

    %{
      group: group,
      is_dual: is_dual,
      quality: quality,
      source: source,
      codec: codec,
      score: score,
      raw_name: folder_name
    }
  end

  defp find_pattern_match(text, patterns) do
    Enum.find_value(patterns, fn {keywords, value} ->
      if Enum.any?(keywords, &String.contains?(text, &1)), do: value
    end)
  end

  defp extract_anime_release_group(folder_name) do
    case Regex.run(~r/^([A-Za-z0-9]+)\s*[\(-]/, folder_name) do
      [_, g] -> g
      nil -> extract_group_from_parens(folder_name)
    end
  end

  defp extract_group_from_parens(folder_name) do
    case Regex.run(~r/\(([A-Za-z0-9]+)\)/, folder_name) do
      [_, g] -> g
      nil -> nil
    end
  end

  defp calculate_release_score(quality, source, codec, is_dual) do
    quality_score = Map.get(@quality_scores, quality, 0)
    source_score = Map.get(@source_scores, source, 0)
    codec_score = Map.get(@codec_scores, codec, 0)
    dual_score = if is_dual, do: 20, else: 0

    quality_score + source_score + codec_score + dual_score
  end

  @doc """
  Parses a season folder name.

  Supports multiple formats:
  - "S01", "S02" (short format)
  - "Season 1", "Season 2" (long format)
  - "Nome.S01.1080p.WEB-DL.Group" (release folder)

  ## Examples

      iex> Parser.parse_season_folder("S01")
      %{season_number: 1}

      iex> Parser.parse_season_folder("Season 2")
      %{season_number: 2}

      iex> Parser.parse_season_folder("13.Reasons.Why.S01.1080p.NF.WEB-DL")
      %{season_number: 1}
  """
  @season_patterns [
    ~r/^S(\d{1,2})$/i,
    ~r/^Season\s*(\d{1,2})$/i,
    ~r/\.S(\d{1,2})\./i,
    ~r/S(\d{1,2})/i
  ]

  def parse_season_folder(nil), do: %{season_number: 1}

  def parse_season_folder(folder_name) when is_binary(folder_name) do
    folder_name = String.trim(folder_name)

    season_number =
      Enum.find_value(@season_patterns, 1, fn pattern ->
        case Regex.run(pattern, folder_name) do
          [_, season] -> String.to_integer(season)
          nil -> nil
        end
      end)

    %{season_number: season_number}
  end

  @doc """
  Parses a movie/video file name (release name format).

  ## Examples

      iex> Parser.parse_release_name("Weapons.2025.1080p.AMZN.WEB-DL.DDP5.1.H.264.DUAL-C76.mkv")
      %{
        name: "Weapons",
        year: 2025,
        quality: "1080p",
        source: "AMZN",
        codec: "WEB-DL",
        audio: "DDP5.1",
        release_group: "C76",
        extension: "mkv",
        is_dual_audio: true
      }
  """
  def parse_release_name(nil),
    do: %{
      name: nil,
      year: nil,
      quality: nil,
      source: nil,
      codec: nil,
      audio: nil,
      release_group: nil,
      extension: nil,
      is_dual_audio: false
    }

  def parse_release_name(filename) when is_binary(filename) do
    filename = String.trim(filename)

    # Remove extension
    {name_without_ext, extension} = split_extension(filename)

    # Replace dots with spaces for easier parsing
    parts = String.split(name_without_ext, ".")

    # Extract year (4 digits starting with 19 or 20)
    {name_parts, rest_parts, year} = extract_year(parts)

    # Extract quality
    {quality, rest_parts} = extract_pattern(rest_parts, @quality_patterns)

    # Extract source
    {source, rest_parts} = extract_pattern(rest_parts, @source_patterns)

    # Check for dual audio (filter nils first)
    is_dual =
      Enum.any?(rest_parts, fn part -> is_binary(part) and String.upcase(part) == "DUAL" end)

    # Extract release group (usually after last dash)
    release_group = extract_release_group(name_without_ext)

    # Build name from name parts
    name = Enum.join(name_parts, " ")

    %{
      name: name,
      year: year,
      quality: quality,
      source: source,
      release_group: release_group,
      extension: extension,
      is_dual_audio: is_dual,
      raw_filename: filename
    }
  end

  @doc """
  Parses an episode file name.

  ## Examples

      iex> Parser.parse_episode_name("13.Reasons.Why.S01E01.1080p.NF.WEB-DL.DD5.1.x264-ZMG.mkv")
      %{
        series_name: "13 Reasons Why",
        season: 1,
        episode: 1,
        title: nil,
        quality: "1080p",
        source: "NF",
        extension: "mkv"
      }

      iex> Parser.parse_episode_name("A.Grande.Familia.S01E01.Meu.Marido.Me.Trata.1080p.WEB-DL.mkv")
      %{
        series_name: "A Grande Familia",
        season: 1,
        episode: 1,
        title: "Meu Marido Me Trata",
        quality: "1080p",
        ...
      }
  """
  def parse_episode_name(nil),
    do: %{
      series_name: nil,
      season: nil,
      episode: nil,
      title: nil,
      quality: nil,
      source: nil,
      release_group: nil,
      extension: nil,
      raw_filename: nil
    }

  def parse_episode_name(filename) when is_binary(filename) do
    filename = String.trim(filename)
    {name_without_ext, extension} = split_extension(filename)

    # Find S01E01 pattern
    case Regex.run(~r/^(.+?)\.S(\d{1,2})E(\d{1,2})\.(.+)$/i, name_without_ext) do
      [_, series_name, season, episode, rest] ->
        series_name = String.replace(series_name, ".", " ")
        rest_parts = String.split(rest, ".")

        {quality, rest_parts} = extract_pattern(rest_parts, @quality_patterns)
        {source, rest_parts} = extract_pattern(rest_parts, @source_patterns)
        release_group = extract_release_group(name_without_ext)

        # Extract title (parts before quality/source patterns)
        title = extract_episode_title(rest_parts)

        %{
          series_name: series_name,
          season: String.to_integer(season),
          episode: String.to_integer(episode),
          title: title,
          quality: quality,
          source: source,
          release_group: release_group,
          extension: extension,
          raw_filename: filename
        }

      nil ->
        # Fallback for other patterns
        %{
          series_name: name_without_ext,
          season: nil,
          episode: nil,
          title: nil,
          quality: nil,
          source: nil,
          release_group: nil,
          extension: extension,
          raw_filename: filename
        }
    end
  end

  @doc """
  Determines if a filename is a video file.
  """
  def video_file?(nil), do: false

  def video_file?(filename) when is_binary(filename) do
    {_, ext} = split_extension(filename)
    String.downcase(ext || "") in @video_extensions
  end

  @doc """
  Extracts the file extension.
  """
  def split_extension(nil), do: {nil, nil}

  def split_extension(filename) when is_binary(filename) do
    case Path.extname(filename) do
      "" -> {filename, nil}
      ext -> {String.trim_trailing(filename, ext), String.trim_leading(ext, ".")}
    end
  end

  @doc """
  Generates a unique stream_id from a GIndex path.
  Uses a hash of the path to create a stable integer ID.
  """
  def path_to_stream_id(path) do
    :erlang.phash2(path)
  end

  @doc """
  Parses a human-readable file size to bytes.

  ## Examples

      iex> Parser.parse_file_size("7.59 GB")
      8151248076

      iex> Parser.parse_file_size("2.15 GB")
      2308743168
  """
  def parse_file_size(size_str) when is_binary(size_str) do
    size_str = String.trim(size_str)

    case Regex.run(~r/^([\d.]+)\s*(GB|MB|KB|B)?$/i, size_str) do
      [_, num, unit] ->
        num = parse_float(num)
        multiplier = size_multiplier(String.upcase(unit || "B"))
        round(num * multiplier)

      nil ->
        0
    end
  end

  def parse_file_size(_), do: 0

  # Private functions

  defp extract_year(parts) do
    year_index =
      Enum.find_index(parts, fn part ->
        case Integer.parse(part) do
          {num, ""} when num >= 1900 and num <= 2100 -> true
          _ -> false
        end
      end)

    case year_index do
      nil ->
        {parts, [], nil}

      idx ->
        name_parts = Enum.take(parts, idx)
        rest_parts = Enum.drop(parts, idx + 1)
        year = parts |> Enum.at(idx) |> String.to_integer()
        {name_parts, rest_parts, year}
    end
  end

  defp extract_pattern(parts, patterns) do
    patterns_upper = Enum.map(patterns, &String.upcase/1)

    index =
      Enum.find_index(parts, fn part ->
        is_binary(part) and String.upcase(part) in patterns_upper
      end)

    case index do
      nil ->
        {nil, parts}

      idx ->
        pattern = Enum.at(parts, idx)
        rest = List.delete_at(parts, idx)
        {pattern, rest}
    end
  end

  defp extract_release_group(name) do
    case Regex.run(~r/-([A-Za-z0-9]+)(?:\.[a-z]+)?$/, name) do
      [_, group] -> group
      nil -> nil
    end
  end

  # Patterns that indicate technical info (not episode title)
  @tech_patterns ~w(DDP DDP5 DD5 DD2 AAC AAC2 AC3 H264 H.264 x264 x265 H265 H.265 HEVC
                   DUAL REMUX PROPER REPACK WEB HDTV DVB AMZN NF HMAX HBO DSNP ATVP GLBO
                   WEB-DL WEBRip BluRay BDRip HDRip DVDRip 1080p 720p 480p 2160p 4K UHD HDR)

  defp extract_episode_title(rest_parts) do
    # Filter out technical info patterns and release group tags
    title_parts =
      rest_parts
      |> Enum.reject(fn
        # Skip nil or non-string parts
        part when not is_binary(part) ->
          true

        part ->
          upcase_part = String.upcase(part)
          # Reject if it matches any tech pattern
          # Reject codec patterns like "1" in "DD5.1"
          # Reject release group patterns (typically at end after dash)
          Enum.any?(@tech_patterns, fn pattern ->
            String.upcase(pattern) == upcase_part or
              String.contains?(upcase_part, String.upcase(pattern))
          end) or
            Regex.match?(~r/^\d+$/, part) or
            Regex.match?(~r/^[A-Z]{2,}$/, part)
      end)

    case title_parts do
      [] -> nil
      parts -> parts |> Enum.join(" ") |> String.trim()
    end
  end

  defp parse_float(str) do
    case Float.parse(str) do
      {num, _} -> num
      :error -> 0.0
    end
  end

  defp size_multiplier("GB"), do: 1024 * 1024 * 1024
  defp size_multiplier("MB"), do: 1024 * 1024
  defp size_multiplier("KB"), do: 1024
  defp size_multiplier(_), do: 1
end
