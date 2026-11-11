defmodule StreamixWeb.StationPaths do
  @moduledoc """
  Where a 24h station sends its viewers, and the Presence topic that counts
  them. Shared by the stations page and the player's station mode.
  """

  use StreamixWeb, :verified_routes

  alias Streamix.Programming

  @doc "The player path for a station's slot: its film or episode, from the slot's offset."
  @spec watch(String.t(), map()) :: String.t()
  def watch(slug, %{item: item, offset: offset}) do
    {type, id} = Programming.item_ref(item)
    ~p"/watch/#{type}/#{id}?station=#{slug}&t=#{offset}"
  end

  @doc "The Presence topic of a station's viewers."
  @spec viewers_topic(String.t()) :: String.t()
  def viewers_topic(slug), do: "station_viewers:" <> slug
end
