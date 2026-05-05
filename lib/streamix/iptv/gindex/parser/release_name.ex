defmodule Streamix.Iptv.Gindex.Parser.ReleaseName do
  @moduledoc """
  Movie and series episode release filename parsers.
  """

  alias Streamix.Iptv.Gindex.Parser.{Files, Quality}

  @doc """
  Parses a movie/video file name in release-name format.
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
    {name_without_ext, extension} = Files.split_extension(filename)
    parts = String.split(name_without_ext, ".")

    {name_parts, rest_parts, year} = extract_year(parts)
    {quality, rest_parts} = Quality.extract_pattern(rest_parts, Quality.quality_patterns())
    {source, rest_parts} = Quality.extract_pattern(rest_parts, Quality.source_patterns())

    is_dual =
      Enum.any?(rest_parts, fn part -> is_binary(part) and String.upcase(part) == "DUAL" end)

    release_group = extract_release_group(name_without_ext)
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
  Parses a series episode file name.
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
    {name_without_ext, extension} = Files.split_extension(filename)

    case Regex.run(~r/^(.+?)\.S(\d{1,2})E(\d{1,2})\.(.+)$/i, name_without_ext) do
      [_, series_name, season, episode, rest] ->
        parse_structured_episode(
          filename,
          extension,
          name_without_ext,
          series_name,
          season,
          episode,
          rest
        )

      nil ->
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

  defp parse_structured_episode(
         filename,
         extension,
         name_without_ext,
         series_name,
         season,
         episode,
         rest
       ) do
    series_name = String.replace(series_name, ".", " ")
    rest_parts = String.split(rest, ".")

    {quality, rest_parts} = Quality.extract_pattern(rest_parts, Quality.quality_patterns())
    {source, rest_parts} = Quality.extract_pattern(rest_parts, Quality.source_patterns())
    release_group = extract_release_group(name_without_ext)
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
  end

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

  defp extract_release_group(name) do
    case Regex.run(~r/-([A-Za-z0-9]+)(?:\.[a-z]+)?$/, name) do
      [_, group] -> group
      nil -> nil
    end
  end

  defp extract_episode_title(rest_parts) do
    title_parts =
      rest_parts
      |> Enum.reject(fn
        part when not is_binary(part) ->
          true

        part ->
          technical_token?(part)
      end)

    case title_parts do
      [] -> nil
      parts -> parts |> Enum.join(" ") |> String.trim()
    end
  end

  defp technical_token?(part) do
    upcase_part = String.upcase(part)

    Enum.any?(Quality.tech_patterns(), fn pattern ->
      String.upcase(pattern) == upcase_part or
        String.contains?(upcase_part, String.upcase(pattern))
    end) or
      Regex.match?(~r/^\d+$/, part) or
      Regex.match?(~r/^[A-Z]{2,}$/, part)
  end
end
