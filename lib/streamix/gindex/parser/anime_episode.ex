defmodule Streamix.Gindex.Parser.AnimeEpisode do
  @moduledoc """
  Anime episode filename parser.
  """

  alias Streamix.Gindex.Parser.Files

  @doc """
  Parses an anime episode filename.
  """
  def parse(nil),
    do: %{episode: nil, season: nil, group: nil, quality: nil, extension: nil, is_dual: false}

  def parse(filename) when is_binary(filename) do
    filename = String.trim(filename)
    {name_without_ext, extension} = Files.split_extension(filename)

    {season, episode} = extract_season_and_episode(name_without_ext)
    group = extract_group(name_without_ext)
    quality = extract_quality(name_without_ext)
    is_dual = String.contains?(String.downcase(name_without_ext), "dual")

    %{
      episode: episode,
      season: season,
      group: group,
      quality: quality,
      extension: extension,
      is_dual_audio: is_dual,
      raw_filename: filename
    }
  end

  defp extract_group(name_without_ext) do
    case Regex.run(~r/^\[([^\]]+)\]/, name_without_ext) do
      [_, group] -> group
      nil -> nil
    end
  end

  defp extract_quality(name_without_ext) do
    case Regex.run(~r/-\s*\d{1,3}\s*\[([^\]]+)\]/, name_without_ext) do
      [_, quality] -> quality
      nil -> nil
    end
  end

  # `SxxEyy` and `NxNN` name a season as well as an episode, and both have to
  # be kept. Reading only the episode out of them put files from different
  # seasons into one — a flat folder holding `3x11` beside `S05e11` had both
  # land on episode 11 of the same season, where the unique index allows one
  # and the other was dropped.
  #
  # Only `Parser.ReleaseName` used to supply a season, and only from the
  # dot-separated `Title.S05E03.rest` shape, so `3x11` and `Title - S01E02
  # [1080p]` had nowhere to put theirs.
  defp extract_season_and_episode(name) do
    case season_episode_marker(name) do
      {_season, _episode} = pair -> pair
      nil -> {nil, extract_anime_episode_number(name)}
    end
  end

  defp season_episode_marker(name) do
    [
      ~r/\bS(\d{1,2})[\s._-]?E(\d{1,3})\b/i,
      ~r/\b(\d{1,2})x(\d{1,3})\b/
    ]
    |> Enum.find_value(fn regex ->
      with [_, season, episode] <- Regex.run(regex, name),
           season when is_integer(season) <- safe_integer(season),
           episode when is_integer(episode) <- safe_integer(episode) do
        {season, episode}
      else
        _other -> nil
      end
    end)
  end

  # Order matters: specific fansub layouts must win before the bare-number
  # fallback so extras, years, and resolutions do not become fake episodes.
  defp extract_anime_episode_number(name) do
    patterns = [
      ~r/-\s*(\d{1,3})\s*\[/,
      ~r/-\s*(\d{1,3})(?:\.|$)/,
      ~r/(?:Epis[oó]dio)\s*[\.-]?\s*(\d{1,3})\b/iu,
      ~r/\bEp\.?\s*(\d{1,3})\b/i,
      ~r/\bEpisode\s*(\d{1,3})\b/i,
      ~r/(?<!\d)\s(\d{1,3})\s*\[/,
      ~r/_(\d{1,3})[_.]/,
      ~r/#(\d{1,3})\b/
    ]

    patterns
    |> Enum.find_value(fn re ->
      case Regex.run(re, name) do
        [_, ep] -> safe_integer(ep)
        _ -> nil
      end
    end)
    |> case do
      nil -> fallback_anime_episode(name)
      ep -> ep
    end
  end

  defp fallback_anime_episode(name) do
    name
    |> String.replace(~r/\b(?:19|20)\d{2}\b/, " ")
    |> String.replace(~r/\b(?:240|360|480|720|1080|1440|2160|4320)p?\b/i, " ")
    |> (&Regex.run(~r/\b(\d{1,3})\b/, &1)).()
    |> case do
      [_, ep] -> safe_integer(ep)
      _ -> nil
    end
  end

  defp safe_integer(str) do
    case Integer.parse(str) do
      {n, _} when n >= 0 and n <= 999 -> n
      _ -> nil
    end
  end
end
