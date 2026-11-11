defmodule StreamixWeb.StationPaths do
  @moduledoc """
  Where a 24h station sends its viewers, how its items read, and the
  Presence topic that counts viewers. Shared by the stations page and the
  player's station mode.
  """

  use StreamixWeb, :verified_routes

  alias Streamix.Programming
  alias StreamixWeb.Content.DisplayTitle

  @doc "The player path for a station's slot: its film or episode, from the slot's offset."
  @spec watch(String.t(), map()) :: String.t()
  def watch(slug, %{item: item, offset: offset}) do
    {type, id} = Programming.item_ref(item)
    ~p"/watch/#{type}/#{id}?station=#{slug}&t=#{offset}"
  end

  @doc """
  How a program item reads: "Chaves · T4:E2 · A limpeza do pátio" for an
  episode, "Title (1984)" for a film. Provider noise is cleaned here, at
  display time, so stored programs need no rebuild when the cleaning
  improves.
  """
  @spec label(map() | nil) :: String.t()
  def label(nil), do: ""

  def label(%{"subtitle" => subtitle} = item) when is_binary(subtitle) do
    series = DisplayTitle.clean(item["title"])

    case Regex.run(~r/^(T\d+:E\d+)(?: · (.*))?$/u, subtitle) do
      [_, number, raw] -> join([series, number, DisplayTitle.episode_name(raw, item["title"])])
      [_, number] -> join([series, number])
      nil -> join([series, subtitle])
    end
  end

  def label(item), do: "#{DisplayTitle.clean(item["title"])}#{year_suffix(item["year"])}"

  defp join(parts), do: parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")

  # Catalog rows without a known year store 0; say nothing rather than "(0)".
  defp year_suffix(year) when is_integer(year) and year > 0, do: " (#{year})"
  defp year_suffix(_year), do: ""

  @doc "The Presence topic of a station's viewers."
  @spec viewers_topic(String.t()) :: String.t()
  def viewers_topic(slug), do: "station_viewers:" <> slug
end
