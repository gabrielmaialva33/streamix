defmodule StreamixWeb.Catalog.Games do
  @moduledoc "Credential-free sports cards shared by web and TV clients."
  alias Streamix.Catalog
  alias StreamixWeb.Helpers.ImageProxy

  def list(user_id, opts \\ []), do: Enum.map(Catalog.list_games(user_id, opts), &serialize/1)

  def serialize(game) do
    %{
      id: game.id,
      league: game.league,
      title: game.title,
      home: %{name: game.home_name, logo_url: ImageProxy.external(game.home_logo_url)},
      away: %{name: game.away_name, logo_url: ImageProxy.external(game.away_logo_url)},
      starts_at: game.starts_at,
      ends_at: game.ends_at,
      live: game.live,
      channel_id: game.live_channel_id
    }
  end

  def cards(user_id, opts) do
    Enum.map(Catalog.list_games(user_id, opts), fn game ->
      Map.put(serialize(game), :start_time, Calendar.strftime(game.local_starts_at, "%H:%M"))
    end)
  end
end
