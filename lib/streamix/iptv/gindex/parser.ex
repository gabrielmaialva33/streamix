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
  Parses a movie folder name.

  ## Examples

      iex> Parser.parse_movie_folder("A Hora do Mal [Weapons] (2025)")
      %{name: "A Hora do Mal", original_name: "Weapons", year: 2025}

      iex> Parser.parse_movie_folder("Avatar (2009)")
      %{name: "Avatar", original_name: nil, year: 2009}
  """
  def parse_movie_folder(folder_name) do
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
  def parse_release_name(filename) do
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

    # Check for dual audio
    is_dual = Enum.any?(rest_parts, &(String.upcase(&1) == "DUAL"))

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
        quality: "1080p",
        source: "NF",
        extension: "mkv"
      }
  """
  def parse_episode_name(filename) do
    filename = String.trim(filename)
    {name_without_ext, extension} = split_extension(filename)

    # Find S01E01 pattern
    case Regex.run(~r/^(.+?)\.S(\d{1,2})E(\d{1,2})\.(.+)$/i, name_without_ext) do
      [_, series_name, season, episode, rest] ->
        series_name = String.replace(series_name, ".", " ")
        rest_parts = String.split(rest, ".")

        {quality, rest_parts} = extract_pattern(rest_parts, @quality_patterns)
        {source, _rest_parts} = extract_pattern(rest_parts, @source_patterns)
        release_group = extract_release_group(name_without_ext)

        %{
          series_name: series_name,
          season: String.to_integer(season),
          episode: String.to_integer(episode),
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
  def video_file?(filename) do
    {_, ext} = split_extension(filename)
    String.downcase(ext || "") in @video_extensions
  end

  @doc """
  Extracts the file extension.
  """
  def split_extension(filename) do
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
        String.upcase(part) in patterns_upper
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
