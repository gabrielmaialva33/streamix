defmodule StreamixWeb.StationPaths do
  @moduledoc """
  Where a 24h station sends its viewers, and the Presence topic that counts
  them. Shared by the stations page and the player's station mode.
  """

  use StreamixWeb, :verified_routes

  @doc "The player path for a station's slot: its film, from the slot's offset."
  @spec watch(String.t(), map()) :: String.t()
  def watch(slug, %{item: %{"movie_id" => movie_id}, offset: offset}),
    do: ~p"/watch/movie/#{movie_id}?station=#{slug}&t=#{offset}"

  @doc "The Presence topic of a station's viewers."
  @spec viewers_topic(String.t()) :: String.t()
  def viewers_topic(slug), do: "station_viewers:" <> slug
end
