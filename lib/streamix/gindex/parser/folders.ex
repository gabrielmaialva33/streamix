defmodule Streamix.Gindex.Parser.Folders do
  @moduledoc """
  Folder-name parsers for GIndex movie, series, anime, and season folders.
  """

  @doc """
  Parses a movie folder name.
  """
  def parse_movie_folder(nil), do: %{name: nil, original_name: nil, year: nil}

  def parse_movie_folder(folder_name) when is_binary(folder_name) do
    folder_name = String.trim(folder_name)

    case Regex.run(~r/^(.+?)\s*\[(.+?)\]\s*\((\d{4})\)$/, folder_name) do
      [_, name_pt, original, year] ->
        %{
          name: String.trim(name_pt),
          original_name: String.trim(original),
          year: String.to_integer(year)
        }

      nil ->
        parse_simple_year_folder(folder_name)
    end
  end

  @doc """
  Alias for `parse_movie_folder/1`; the same pattern applies to series folders.
  """
  def parse_series_folder(folder_name), do: parse_movie_folder(folder_name)

  @doc """
  Parses an anime folder name.
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

  @doc """
  Parses a season folder name.
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

  defp parse_simple_year_folder(folder_name) do
    case Regex.run(~r/^(.+?)\s*\((\d{4})\)$/, folder_name) do
      [_, name, year] ->
        %{
          name: String.trim(name),
          original_name: nil,
          year: String.to_integer(year)
        }

      nil ->
        %{
          name: folder_name,
          original_name: nil,
          year: nil
        }
    end
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
end
