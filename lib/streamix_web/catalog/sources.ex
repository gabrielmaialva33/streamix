defmodule StreamixWeb.Catalog.Sources do
  @moduledoc """
  Lists the equivalent playable copies ("sources") of one catalog title for
  API clients.

  Nothing here is a new rule. For movies and episodes, discovery, the torrent
  exclusion and the ranking are the web player's failover chain
  (`StreamixWeb.PlayerHelpers.failover_sources/3`, ordered by
  `Streamix.Playback.sort_stream_sources/2`); for series they are the series
  detail page's picker (`StreamixWeb.Content.SeriesSources`). The badges are
  `StreamixWeb.Content.SourceBadges`, and `provider_status` is the
  classification behind `GET /api/v1/providers/status`. This module only
  drops what the API stream endpoint would refuse and shapes the payload.

  The catalog API has no session: callers are API-key integrations and
  `/api/v1/catalog/{movies,episodes}/:id/stream` signs URLs with the
  integration bypass. Candidates are therefore discovered as an anonymous
  viewer (public and global providers only) and kept only when that endpoint
  would sign them.
  """

  alias StreamixWeb.Catalog.Serializer
  alias StreamixWeb.Content.SeriesSources
  alias StreamixWeb.PlayerHelpers

  @doc "Sources of a movie returned by `Streamix.Catalog.get_public_movie/1`."
  @spec for_movie(map()) :: [map()]
  def for_movie(movie), do: playback_sources("movie", movie)

  @doc "Sources of an episode returned by `Streamix.Catalog.get_public_episode/1`."
  @spec for_episode(map()) :: [map()]
  def for_episode(episode), do: playback_sources("episode", episode)

  @doc """
  Series-level sources of a series returned by
  `Streamix.Catalog.get_series_with_sync!/1`: one copy per provider, in the
  series detail page's order.
  """
  @spec for_series(map()) :: [map()]
  def for_series(series) do
    series
    |> SeriesSources.list(nil)
    |> Enum.filter(&stream_endpoint_accepts?(&1.provider))
    |> serialize(series.id, &Serializer.serialize_series_source(&1, SeriesSources.counts(&1), &2))
  end

  defp playback_sources(type, content) do
    type
    |> PlayerHelpers.failover_sources(content, nil)
    |> Enum.filter(&stream_endpoint_accepts?(&1.provider))
    |> serialize(content.id, &Serializer.serialize_source/2)
  end

  defp serialize(sources, current_id, serialize_fun) do
    statuses =
      sources
      |> Enum.map(& &1.provider)
      |> Enum.uniq_by(& &1.id)
      |> Streamix.Providers.provider_health_statuses()

    sources
    |> Enum.with_index()
    |> Enum.map(fn {source, index} ->
      serialize_fun.(source,
        provider_status: Map.get(statuses, source.provider_id, :unknown),
        recommended: index == 0,
        current: source.id == current_id
      )
    end)
  end

  # What `/catalog/{movies,episodes}/:id/stream` signs for an API-key caller:
  # `get_public_movie/1` and `get_public_episode/1` require a public or global
  # provider the operator has not disabled, and the stream proxy refuses
  # torrent rows, which need the swarm-gate lifecycle. The signed URL carries
  # the integration bypass, so the subscription gate
  # (`Streamix.Access.plays_global_content?/2`) does not apply to it. A series
  # copy is offered on the same terms as the episodes it would play.
  defp stream_endpoint_accepts?(provider) do
    provider.visibility in [:global, :public] and provider.is_active == true and
      provider.provider_type not in [:torrent, "torrent"]
  end
end
