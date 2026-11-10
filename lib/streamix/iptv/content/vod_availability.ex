defmodule Streamix.Iptv.Content.VodAvailability do
  @moduledoc """
  Quarantines individual VOD files after a definitive upstream not-found response.
  Provider access and health are independent; a missing file never disables its provider.
  """
  import Ecto.Query
  alias Streamix.{Cache, Repo}
  alias Streamix.Iptv.{CatalogItem, Episode, Movie}
  require Logger

  @recheck_seconds 7 * 24 * 60 * 60

  @spec dead?(map() | term()) :: boolean()
  def dead?(%{dead_since: %DateTime{} = since}), do: DateTime.compare(since, cutoff()) != :lt
  def dead?(_), do: false

  @spec record_failure(term(), term(), term(), term()) :: :ok | {:ok, pid()}
  def record_failure(type, id, provider_id, reason) do
    schema = schema(type)

    if schema && is_integer(id) && is_integer(provider_id) && missing?(reason) do
      start_mark(schema, id, provider_id)
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp start_mark(schema, id, provider_id) do
    observed_at = DateTime.utc_now(:second)

    case Task.Supervisor.start_child(Streamix.TaskSupervisor, fn ->
           mark_dead(schema, id, provider_id, observed_at)
         end) do
      {:ok, pid} -> {:ok, pid}
      _ -> :ok
    end
  end

  defp mark_dead(schema, id, provider_id, observed_at) do
    owned_items =
      from(item in CatalogItem, where: item.provider_id == ^provider_id, select: item.id)

    {count, _} =
      from(content in schema,
        where: content.id == ^id and content.catalog_item_id in subquery(owned_items),
        where: is_nil(content.dead_since) or content.dead_since < ^cutoff(),
        where: content.updated_at <= ^observed_at
      )
      |> Repo.update_all(set: [dead_since: observed_at])

    if count > 0 do
      Cache.invalidate_public_catalog()
      Cache.invalidate_provider(provider_id)
    end

    :ok
  rescue
    _ ->
      Logger.warning("[VOD] Could not record content availability")
      :ok
  end

  @doc "Filters a movie/episode root query; other content types pass through."
  def exclude_dead(queryable) do
    query = Ecto.Queryable.to_query(queryable)

    case query.from.source do
      {table, _schema} when table in ["movies", "episodes"] ->
        where(query, [content], is_nil(content.dead_since) or content.dead_since < ^cutoff())

      _ ->
        query
    end
  end

  @doc "Filters catalog-item projections used by personal/home library rows."
  def exclude_dead_catalog(query) do
    cutoff = cutoff()

    dead_movies =
      from(movie in Movie,
        where:
          movie.catalog_item_id == parent_as(:catalog_item).id and movie.dead_since >= ^cutoff,
        select: 1
      )

    dead_episodes =
      from(episode in Episode,
        where:
          episode.catalog_item_id == parent_as(:catalog_item).id and episode.dead_since >= ^cutoff,
        select: 1
      )

    where(query, not exists(subquery(dead_movies)) and not exists(subquery(dead_episodes)))
  end

  @doc "Preserves quarantine through unchanged syncs; new effective payload data allows another attempt."
  def conflict_update(updates, schema) do
    if schema in [Movie, Episode] do
      changed =
        updates
        |> Enum.reject(fn {key, _} ->
          key in [:updated_at, :dead_since, :tmdb_genre_ids, :tmdb_keyword_ids]
        end)
        |> Enum.reduce(dynamic(false), fn {key, value}, changed ->
          dynamic(
            [content],
            ^changed or fragment("? IS DISTINCT FROM ?", field(content, ^key), ^value)
          )
        end)

      liveness =
        dynamic(
          [content],
          fragment(
            "CASE WHEN ? OR ? < ? THEN NULL ELSE ? END",
            ^changed,
            content.dead_since,
            ^cutoff(),
            content.dead_since
          )
        )

      [{:dead_since, liveness} | updates]
    else
      updates
    end
  end

  defp schema(type) when type in [:movie, "movie"], do: Movie
  defp schema(type) when type in [:episode, "episode"], do: Episode
  defp schema(_), do: nil

  defp missing?({kind, status})
       when kind in [:unexpected_status, :http_error] and status in [404, 410], do: true

  defp missing?(:upstream_not_found), do: true
  defp missing?(_), do: false
  defp cutoff, do: DateTime.utc_now(:second) |> DateTime.add(-@recheck_seconds, :second)
end
