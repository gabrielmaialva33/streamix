defmodule StreamixWeb.Content.SourceBadges do
  @moduledoc """
  The version badges shown for one playable source of a title.

  This is the single definition of the rule: the movie and series detail
  pages' source pickers and `GET /api/v1/catalog/{movies,episodes,series}/:id/sources`
  all call `badges/1`, so the web and TV clients can never label the same
  provider copy differently.

  Markers are read from the raw provider `name`/`title` as whole words,
  ignoring case, because provider catalogs label copies in many shapes:
  `Filme [L]`, `Filme [LEG]`, `Filme Legendado`, `Filme 1080p WEB-DL DUAL`.
  """

  # A delivery format, not something a viewer chooses by.
  @hidden_containers ~w(m3u8 txt)

  # Highest first; a copy shows only its highest resolution.
  @resolutions [
    {~r/(?<![\p{L}\p{N}])(?:2160p|4k|uhd)(?![\p{L}\p{N}])/iu, "4K"},
    {~r/(?<![\p{L}\p{N}])1080p(?![\p{L}\p{N}])/iu, "1080p"},
    {~r/(?<![\p{L}\p{N}])720p(?![\p{L}\p{N}])/iu, "720p"}
  ]

  @hdr ~r/(?<![\p{L}\p{N}])hdr(?:10\+?)?(?![\p{L}\p{N}])/iu
  @dual ~r/(?<![\p{L}\p{N}])dual(?![\p{L}\p{N}])/iu
  @subtitled ~r/\[(?:l|leg|legendado)\]|(?<![\p{L}\p{N}])legendad[oa]s?(?![\p{L}\p{N}])/iu
  @dubbed ~r/\[(?:d|dub|dublado)\]|(?<![\p{L}\p{N}])dublad[oa]s?(?![\p{L}\p{N}])/iu

  @doc """
  Returns the badges for a movie, episode or series row, in display order:
  container (upcased, omitted for HLS delivery formats), the highest
  resolution, HDR, then audio. `DUAL` replaces `DUB`/`LEG`. A series flagged
  `dub_available` is dubbed even when its name says nothing. Missing fields
  are ignored.

      iex> StreamixWeb.Content.SourceBadges.badges(%{
      ...>   name: "Dune 4K Dublado",
      ...>   title: nil,
      ...>   container_extension: "mkv"
      ...> })
      ["MKV", "4K", "DUB"]
  """
  @spec badges(map()) :: [String.t()]
  def badges(source) when is_map(source) do
    label = "#{Map.get(source, :name)} #{Map.get(source, :title)}"

    ([
       container_label(Map.get(source, :container_extension)),
       resolution(label),
       if(label =~ @hdr, do: "HDR")
     ] ++ audio(source, label))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp resolution(label) do
    Enum.find_value(@resolutions, fn {pattern, badge} -> if label =~ pattern, do: badge end)
  end

  defp audio(source, label) do
    if label =~ @dual do
      ["DUAL"]
    else
      [
        if(label =~ @subtitled, do: "LEG"),
        if(label =~ @dubbed or Map.get(source, :dub_available) == true, do: "DUB")
      ]
    end
  end

  defp container_label(extension) when is_binary(extension) and extension != "" do
    if String.downcase(extension) in @hidden_containers, do: nil, else: String.upcase(extension)
  end

  defp container_label(_extension), do: nil
end
