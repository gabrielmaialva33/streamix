defmodule StreamixWeb.Content.SourceBadges do
  @moduledoc """
  The version badges shown for one playable source of a title.

  This is the single definition of the rule: the movie and series detail
  pages' source pickers and `GET /api/v1/catalog/{movies,episodes,series}/:id/sources`
  all call `badges/1`, so the web and TV clients can never label the same
  provider copy differently.
  """

  @markers [
    {"4k", "4K"},
    {"hdr", "HDR"},
    {"legendado", "LEG"},
    {"dublado", "DUB"}
  ]

  @doc """
  Returns the badges for a movie, episode or series row, in display order.

  The container extension comes first (upcased), followed by the quality and
  audio markers found in the raw provider `name`/`title`. A series flagged
  `dub_available` is dubbed even when its name says nothing. Missing fields
  are ignored and duplicates are dropped.

      iex> StreamixWeb.Content.SourceBadges.badges(%{
      ...>   name: "Dune 4K Dublado",
      ...>   title: nil,
      ...>   container_extension: "mkv"
      ...> })
      ["MKV", "4K", "DUB"]
  """
  @spec badges(map()) :: [String.t()]
  def badges(source) when is_map(source) do
    label = String.downcase("#{Map.get(source, :name)} #{Map.get(source, :title)}")

    [
      extension_label(Map.get(source, :container_extension))
      | Enum.map(@markers, fn {needle, badge} ->
          if marked?(source, label, needle), do: badge
        end)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp marked?(source, label, "dublado" = needle),
    do: String.contains?(label, needle) or Map.get(source, :dub_available) == true

  defp marked?(_source, label, needle), do: String.contains?(label, needle)

  defp extension_label(extension) when is_binary(extension) and extension != "",
    do: String.upcase(extension)

  defp extension_label(_extension), do: nil
end
