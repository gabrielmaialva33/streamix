defmodule Streamix.Iptv.Gindex.Parser.Quality do
  @moduledoc """
  Shared technical-token extraction for GIndex release parsers.
  """

  @quality_patterns ~w(2160p 1080p 720p 480p 4K UHD HDR)
  @source_patterns ~w(AMZN NF DSNP HMAX HBO ATVP PMTP WEB-DL WEBRip BluRay BDRip HDRip DVDRip)

  @tech_patterns ~w(DDP DDP5 DD5 DD2 AAC AAC2 AC3 H264 H.264 x264 x265 H265 H.265 HEVC
                   DUAL REMUX PROPER REPACK WEB HDTV DVB AMZN NF HMAX HBO DSNP ATVP GLBO
                   WEB-DL WEBRip BluRay BDRip HDRip DVDRip 1080p 720p 480p 2160p 4K UHD HDR)

  def quality_patterns, do: @quality_patterns
  def source_patterns, do: @source_patterns
  def tech_patterns, do: @tech_patterns

  def extract_pattern(parts, patterns) do
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
end
