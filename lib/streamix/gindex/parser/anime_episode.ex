defmodule Streamix.Gindex.Parser.AnimeEpisode do
  @moduledoc """
  Anime episode filename parser.
  """

  alias Streamix.Gindex.Parser.Files

  @doc """
  Parses an anime episode filename.
  """
  def parse(nil),
    do: %{episode: nil, group: nil, quality: nil, extension: nil, is_dual: false}

  def parse(filename) when is_binary(filename) do
    filename = String.trim(filename)
    {name_without_ext, extension} = Files.split_extension(filename)

    episode = extract_anime_episode_number(name_without_ext)
    group = extract_group(name_without_ext)
    quality = extract_quality(name_without_ext)
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
