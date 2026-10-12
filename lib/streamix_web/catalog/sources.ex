defmodule StreamixWeb.Catalog.Sources do
  @moduledoc """
  Lists the equivalent playable copies ("sources") of one catalog title for
  API clients.

  Nothing here is a new rule. Discovery, the torrent exclusion and the ranking
  are the web player's failover chain (`StreamixWeb.PlayerHelpers.failover_sources/3`,
  ordered by `Streamix.Playback.sort_stream_sources/2`), the badges are
  `StreamixWeb.Content.SourceBadges`, and `provider_status` is the
  classification behind `GET /api/v1/providers/status`. This module only drops
  what the API stream endpoint would refuse and shapes the payload.

  The catalog API has no session: callers are API-key integrations and
  `/api/v1/catalog/{movies,episodes}/:id/stream` signs URLs with the
  integration bypass. Candidates are therefore discovered as an anonymous
  viewer (public and global providers only) and kept only when that endpoint
  would sign them.
  """

  alias StreamixWeb.Catalog.Serializer
  alias StreamixWeb.PlayerHelpers

  @doc "Sources of a movie returned by `Streamix.Catalog.get_public_movie/1`."
  @spec for_movie(map()) :: [map()]
  def for_movie(movie), do: list("movie", movie)

  @doc "Sources of an episode returned by `Streamix.Catalog.get_public_episode/1`."
  @spec for_episode(map()) :: [map()]
  def for_episode(episode), do: list("episode", episode)

  defp list(type, content) do
    candidates =
      type
      |> PlayerHelpers.failover_sources(content, nil)
      |> Enum.filter(&stream_endpoint_accepts?/1)

    statuses =
      candidates
      |> Enum.map(& &1.provider)
      |> Enum.uniq_by(& &1.id)
      |> Streamix.Providers.provider_health_statuses()

    candidates
    |> Enum.with_index()
    |> Enum.map(fn {candidate, index} ->
      Serializer.serialize_source(candidate, Map.get(statuses, candidate.provider_id, :unknown),
        recommended: index == 0,
        current: candidate.id == content.id
      )
    end)
  end

  # What `/catalog/{movies,episodes}/:id/stream` signs for an API-key caller:
  # `get_public_movie/1` and `get_public_episode/1` require a public or global
  # provider the operator has not disabled, and the stream proxy refuses
  # torrent rows, which need the swarm-gate lifecycle. The signed URL carries
  # the integration bypass, so the subscription gate
  # (`Streamix.Access.plays_global_content?/2`) does not apply to it.
  defp stream_endpoint_accepts?(%{provider: provider}) do
    provider.visibility in [:global, :public] and provider.is_active == true and
      provider.provider_type not in [:torrent, "torrent"]
  end
end
