defmodule StreamixWeb.Content.SourceBadges do
  @moduledoc """
  The version badges shown for one playable source of a title.

  This is the single definition of the rule: the movie detail page's source
  picker and `GET /api/v1/catalog/{movies,episodes}/:id/sources` both call
  `badges/1`, so the web and TV clients can never label the same provider
  copy differently.
  """

  @markers [
    {"4k", "4K"},
    {"hdr", "HDR"},
    {"legendado", "LEG"},
    {"dublado", "DUB"}
  ]

  @doc """
  Returns the badges for a movie or episode row, in display order.

  The container extension comes first (upcased), followed by the quality and
  audio markers found in the raw provider `name`/`title`. Missing fields are
  ignored and duplicates are dropped.

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
          if String.contains?(label, needle), do: badge
        end)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extension_label(extension) when is_binary(extension) and extension != "",
    do: String.upcase(extension)

  defp extension_label(_extension), do: nil
end
