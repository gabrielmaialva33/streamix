defmodule Streamix.Gindex.Parser.ReleaseFolder do
  @moduledoc """
  Parses and scores anime release folder names.
  """

  @release_quality_patterns [
    {["2160P", "4K"], "2160p"},
    {["1080P"], "1080p"},
    {["720P"], "720p"},
    {["480P"], "480p"}
  ]

  @release_source_patterns [
    {["BDREMUX", "REMUX"], "BDRemux"},
    {["BD ", "BLURAY"], "BD"},
    {["WEB-DL"], "WEB-DL"},
    {["WEBRIP"], "WEBRip"},
    {["HDTV"], "HDTV"}
  ]

  @release_codec_patterns [
    {["HEVC", "X265", "H.265"], "HEVC"},
    {["X264", "H.264"], "H.264"}
  ]

  @quality_scores %{"2160p" => 40, "1080p" => 30, "720p" => 20, "480p" => 10}
  @source_scores %{"BDRemux" => 25, "BD" => 20, "WEB-DL" => 15, "WEBRip" => 10, "HDTV" => 5}
  @codec_scores %{"HEVC" => 10, "H.264" => 5}

  def parse(nil),
    do: %{
      group: nil,
      is_dual: false,
      quality: nil,
      source: nil,
      codec: nil,
      score: 0,
      raw_name: nil
    }

  def parse(folder_name) when is_binary(folder_name) do
    folder_name = String.trim(folder_name)
    upcase_name = String.upcase(folder_name)

    is_dual = String.contains?(upcase_name, "DUAL")
    quality = find_pattern_match(upcase_name, @release_quality_patterns)
    source = find_pattern_match(upcase_name, @release_source_patterns)
    codec = find_pattern_match(upcase_name, @release_codec_patterns)
    group = extract_anime_release_group(folder_name)

    %{
      group: group,
      is_dual: is_dual,
      quality: quality,
      source: source,
      codec: codec,
      score: calculate_score(quality, source, codec, is_dual),
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
      [_, group] -> group
      nil -> extract_group_from_parens(folder_name)
    end
  end

  defp extract_group_from_parens(folder_name) do
    case Regex.run(~r/\(([A-Za-z0-9]+)\)/, folder_name) do
      [_, group] -> group
      nil -> nil
    end
  end

  defp calculate_score(quality, source, codec, is_dual) do
    quality_score = Map.get(@quality_scores, quality, 0)
    source_score = Map.get(@source_scores, source, 0)
    codec_score = Map.get(@codec_scores, codec, 0)
    dual_score = if is_dual, do: 20, else: 0

    quality_score + source_score + codec_score + dual_score
  end
end
