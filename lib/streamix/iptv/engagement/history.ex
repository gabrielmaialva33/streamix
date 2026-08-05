defmodule Streamix.Iptv.History do
  @moduledoc """
  Watch history management backed by WatchProgress (upsert-style)
  and WatchEvent (append-only log).
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Streamix.Iptv.{CatalogItem, Episode, Season, WatchProgress}
  alias Streamix.Iptv.ContentRef
  alias Streamix.Iptv.Engagement.ContentPolicy
  alias Streamix.Repo

  @catalog_preloads [catalog_item: [:movie, :series, :episode, :live_channel]]

  @doc """
  Lists watch progress for a user with optional filters.

  ## Options
    * `:limit` - Maximum number of results (default: 50)
    * `:offset` - Number of results to skip (default: 0)
    * `:content_type` - Filter by content type ("movie", "episode", "live_channel")
  """
  @spec list(integer(), keyword()) :: [map()]
  def list(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    content_type = Keyword.get(opts, :content_type)
    show_adult = Keyword.get(opts, :show_adult, false)

    user_progress_query(user_id)
    |> ContentPolicy.visible_to_user(user_id)
    |> maybe_filter_by_type(content_type)
    |> maybe_exclude_adult(show_adult)
    |> order_by([progress: progress], desc: progress.last_watched_at)
    |> preload(^@catalog_preloads)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
    |> Enum.map(fn entry ->
      entry
      |> ContentRef.decorate()
      |> Map.put(:watched_at, entry.last_watched_at)
    end)
  end

  @doc """
  Lists lightweight watch history cards for home surfaces without generic content preloads.
  """
  @spec list_home(integer(), keyword()) :: [map()]
  def list_home(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    content_type = Keyword.get(opts, :content_type)
    show_adult = Keyword.get(opts, :show_adult, false)

    user_progress_query(user_id)
    |> ContentPolicy.visible_to_user(user_id)
    |> maybe_filter_by_type(content_type)
    |> maybe_exclude_adult(show_adult)
    |> join_home_content()
    |> order_by([progress: progress], desc: progress.last_watched_at)
    |> limit(^limit)
    |> offset(^offset)
    |> select_home_card()
    |> Repo.all()
    |> Enum.map(&build_home_card/1)
    # Drop entries whose content row was deleted (e.g. after a provider
    # migration): build_home_card leaves content_id nil and the home card
    # would otherwise call watch_path(_, nil) and crash the whole LiveView.
    |> Enum.reject(&is_nil(&1.content_id))
  end

  @doc """
  Lists lightweight watch history entries for analytics without catalog preloads.
  """
  @spec list_for_analytics(integer(), keyword()) :: [map()]
  def list_for_analytics(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    content_type = Keyword.get(opts, :content_type)
    show_adult = Keyword.get(opts, :show_adult, false)

    # CASE over catalog_item.content_type picks the right subquery for each
    # row instead of running all four — was a 4× scalar subquery per row,
    # which on a 100-row history meant 400 index lookups vs 100 with the
    # CASE form. Same total result, fraction of the planner work.
    user_progress_query(user_id)
    |> ContentPolicy.visible_to_user(user_id)
    |> maybe_filter_by_type(content_type)
    |> maybe_exclude_adult(show_adult)
    |> order_by([progress: progress], desc: progress.last_watched_at)
    |> limit(^limit)
    |> offset(^offset)
    |> select([progress: progress, catalog_item: catalog_item], %{
      content_type: catalog_item.content_type,
      content_id:
        selected_as(
          fragment(
            """
            CASE ?
              WHEN 'movie' THEN (SELECT m0.id FROM movies AS m0 WHERE m0.catalog_item_id = ?)
              WHEN 'series' THEN (SELECT s0.id FROM series AS s0 WHERE s0.catalog_item_id = ?)
              WHEN 'episode' THEN (SELECT e0.id FROM episodes AS e0 WHERE e0.catalog_item_id = ?)
              WHEN 'live_channel' THEN (SELECT l0.id FROM live_channels AS l0 WHERE l0.catalog_item_id = ?)
            END
            """,
            catalog_item.content_type,
            progress.catalog_item_id,
            progress.catalog_item_id,
            progress.catalog_item_id,
            progress.catalog_item_id
          ),
          :content_id
        ),
      series_id:
        fragment(
          """
          CASE WHEN ? = 'episode' THEN (
            SELECT history_season.series_id
            FROM episodes AS history_episode
            JOIN seasons AS history_season ON history_season.id = history_episode.season_id
            WHERE history_episode.catalog_item_id = ?
          ) END
          """,
          catalog_item.content_type,
          progress.catalog_item_id
        ),
      progress_seconds: progress.progress_seconds,
      duration_seconds: progress.duration_seconds,
      completed: progress.completed,
      watched_at: progress.last_watched_at
    })
    |> Repo.all()
    # Provider resyncs can delete a content row while its CatalogItem (and
    # therefore WatchProgress) survives until orphan cleanup. Analytics
    # consumers send content_id to Qdrant, where JSON null is not a valid
    # point ID, so omit those stale rows at the read boundary.
    |> Enum.reject(&is_nil(&1.content_id))
  end

  @doc """
  Counts watch progress grouped by content type for a user.
  Returns a map like %{"movie" => 10, "episode" => 15, "live_channel" => 3}
  """
  @spec count_by_type(integer(), keyword()) :: %{String.t() => integer()}
  def count_by_type(user_id, opts \\ []) do
    WatchProgress
    |> user_progress_query(user_id)
    |> ContentPolicy.visible_to_user(user_id)
    |> maybe_exclude_adult(Keyword.get(opts, :show_adult, false))
    |> group_by([catalog_item: catalog_item], catalog_item.content_type)
    |> select([catalog_item: catalog_item], {catalog_item.content_type, count()})
    |> Repo.all()
    |> Enum.into(%{})
  end

  @doc """
  Upserts a watch progress entry. If one exists for this user + catalog_item,
  it updates; otherwise inserts.
  """
  @spec add(integer(), String.t(), integer() | String.t(), map()) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  def add(user_id, content_type, content_id, attrs \\ %{}) do
    with {:ok, normalized_id} <- ContentRef.normalize_id(content_id),
         {:ok, catalog_item_id} <- ContentRef.resolve_catalog_item_id(content_type, normalized_id),
         true <- ContentPolicy.visible_catalog_item?(user_id, catalog_item_id) do
      upsert_progress(user_id, catalog_item_id, attrs)
    else
      {:error, :invalid_content_id} ->
        {:error,
         Changeset.change(%WatchProgress{})
         |> Changeset.add_error(:content_id, "is invalid")}

      {:error, :invalid_content_type} ->
        {:error,
         Changeset.change(%WatchProgress{})
         |> Changeset.add_error(:content_type, "is invalid")}

      {:error, :not_found} ->
        {:error,
         Changeset.change(%WatchProgress{})
         |> Changeset.add_error(:content_id, "content not found")}

      false ->
        {:error,
         Changeset.change(%WatchProgress{})
         |> Changeset.add_error(:content_id, "content not found")}
    end
  end

  @doc """
  Adds a watch progress entry from a map of attributes (convenience for PlayerLive).
  """
  @spec add(integer(), map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def add(user_id, attrs) when is_map(attrs) do
    add(
      user_id,
      attrs[:content_type] || attrs["content_type"],
      attrs[:content_id] || attrs["content_id"],
      attrs
    )
  end

  @doc """
  Updates viewing progress for content.
  Marks as completed if progress reaches 90% of duration.
  """
  @spec update_progress(integer(), String.t(), integer(), integer(), integer() | nil) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  def update_progress(
        user_id,
        content_type,
        content_id,
        progress_seconds,
        duration_seconds \\ nil
      ) do
    attrs = %{progress_seconds: progress_seconds}

    attrs =
      if duration_seconds, do: Map.put(attrs, :duration_seconds, duration_seconds), else: attrs

    attrs =
      if duration_seconds && progress_seconds >= duration_seconds * 0.9 do
        Map.put(attrs, :completed, true)
      else
        attrs
      end

    add(user_id, content_type, content_id, attrs)
  end

  @doc """
  Updates watch progress from PlayerLive events.
  Handles nil duration for live streams.
  """
  @spec update_watch_progress(integer(), String.t(), integer(), number() | nil, number() | nil) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  def update_watch_progress(user_id, content_type, content_id, current_time, duration) do
    duration_rounded = if duration, do: round(duration), else: nil
    update_progress(user_id, content_type, content_id, round(current_time || 0), duration_rounded)
  end

  @doc """
  Updates only the duration_seconds field.
  """
  @spec update_watch_time(integer(), String.t(), integer(), number()) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  def update_watch_time(user_id, content_type, content_id, duration_seconds) do
    add(user_id, content_type, content_id, %{duration_seconds: round(duration_seconds)})
  end

  @doc """
  Removes a single watch progress entry by its ID.
  """
  @spec remove(integer(), integer()) :: {integer(), nil}
  def remove(user_id, entry_id) do
    WatchProgress
    |> where(user_id: ^user_id, id: ^entry_id)
    |> Repo.delete_all()
  end

  @doc """
  Clears all watch progress for a user.
  Returns {:ok, count} with number of deleted entries.
  """
  @spec clear(integer()) :: {:ok, integer()}
  def clear(user_id) do
    {count, _} =
      WatchProgress
      |> where(user_id: ^user_id)
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc """
  Returns a map of series_id => progress (0.0..1.0) based on the latest watched episode.
  Used for showing progress bars on series cards.
  """
  @spec get_series_progress_map(integer(), [integer()]) :: %{integer() => float()}
  def get_series_progress_map(_user_id, []), do: %{}

  def get_series_progress_map(user_id, series_ids) do
    WatchProgress
    |> join(:inner, [wp], episode in Episode, on: episode.catalog_item_id == wp.catalog_item_id)
    |> join(:inner, [_wp, episode], season in Season, on: season.id == episode.season_id)
    |> where([wp, _episode, season], wp.user_id == ^user_id and season.series_id in ^series_ids)
    |> where([wp], wp.duration_seconds > 0 and wp.progress_seconds > 0)
    |> order_by([wp, _episode, season],
      asc: season.series_id,
      desc: wp.last_watched_at,
      desc: wp.id
    )
    |> distinct([_wp, _episode, season], season.series_id)
    |> select(
      [wp, _episode, season],
      {season.series_id, wp.progress_seconds, wp.duration_seconds}
    )
    |> Repo.all()
    |> Map.new(fn {series_id, progress, duration} ->
      {series_id, Float.round(progress / duration, 2)}
    end)
  end

  @doc """
  Returns a map of content_id => progress (0.0..1.0) for the given content IDs.
  Used for showing progress bars on content cards.
  """
  @spec get_progress_map(integer(), String.t(), [integer()]) :: %{integer() => float()}
  def get_progress_map(_user_id, _content_type, []), do: %{}

  def get_progress_map(user_id, content_type, content_ids) do
    case content_schema(content_type) do
      nil -> %{}
      schema -> do_get_progress_map(user_id, schema, content_ids)
    end
  end

  defp do_get_progress_map(user_id, schema, content_ids) do
    from(content in schema,
      as: :content,
      join: progress in WatchProgress,
      as: :progress,
      on: progress.catalog_item_id == content.catalog_item_id,
      where: content.id in ^content_ids,
      where: progress.user_id == ^user_id,
      where: progress.duration_seconds > 0 and progress.progress_seconds > 0,
      select: {content.id, progress.progress_seconds, progress.duration_seconds}
    )
    |> Repo.all()
    |> Map.new(fn {content_id, progress, duration} ->
      {content_id, Float.round(progress / duration, 2)}
    end)
  end

  # --- Private ---

  defp upsert_progress(user_id, catalog_item_id, attrs) do
    now = DateTime.utc_now(:second)

    attrs =
      attrs
      |> Map.put(:user_id, user_id)
      |> Map.put(:catalog_item_id, catalog_item_id)
      |> Map.put(:last_watched_at, now)

    case Repo.one(
           from(wp in WatchProgress,
             where: wp.user_id == ^user_id and wp.catalog_item_id == ^catalog_item_id
           )
         ) do
      nil ->
        %WatchProgress{}
        |> WatchProgress.changeset(attrs)
        |> Repo.insert()
        |> maybe_decorate()

      %WatchProgress{} = existing ->
        existing
        |> WatchProgress.changeset(attrs)
        |> Repo.update()
        |> maybe_decorate()
    end
  end

  defp user_progress_query(user_id), do: user_progress_query(WatchProgress, user_id)

  defp user_progress_query(queryable, user_id) do
    from(progress in queryable,
      as: :progress,
      where: progress.user_id == ^user_id,
      join: catalog_item in CatalogItem,
      as: :catalog_item,
      on: progress.catalog_item_id == catalog_item.id
    )
  end

  defp maybe_filter_by_type(query, nil), do: query

  defp maybe_filter_by_type(query, content_type) do
    where(query, [catalog_item: catalog_item], catalog_item.content_type == ^content_type)
  end

  defp maybe_exclude_adult(query, true), do: query
  defp maybe_exclude_adult(query, false), do: ContentPolicy.exclude_adult(query)

  defp maybe_decorate({:ok, entry}) do
    entry
    |> Repo.preload(@catalog_preloads)
    |> ContentRef.decorate()
    |> Map.put(:watched_at, entry.last_watched_at)
    |> then(&{:ok, &1})
  end

  defp maybe_decorate({:error, changeset}), do: {:error, changeset}

  defp join_home_content(query) do
    query
    |> join(:left, [catalog_item: catalog_item], movie in assoc(catalog_item, :movie), as: :movie)
    |> join(:left, [catalog_item: catalog_item], series in assoc(catalog_item, :series),
      as: :series
    )
    |> join(:left, [catalog_item: catalog_item], episode in assoc(catalog_item, :episode),
      as: :episode
    )
    |> join(:left, [catalog_item: catalog_item], channel in assoc(catalog_item, :live_channel),
      as: :channel
    )
  end

  defp select_home_card(query) do
    select(
      query,
      [
        progress: progress,
        catalog_item: catalog_item,
        movie: movie,
        series: series,
        episode: episode,
        channel: channel
      ],
      %{
        id: progress.id,
        progress_seconds: progress.progress_seconds,
        duration_seconds: progress.duration_seconds,
        watched_at: progress.last_watched_at,
        content_type: catalog_item.content_type,
        movie_id: movie.id,
        movie_name: movie.name,
        movie_icon: movie.stream_icon,
        series_id: series.id,
        series_name: series.name,
        series_icon: series.cover,
        episode_id: episode.id,
        episode_name: episode.title,
        episode_icon: episode.still_path,
        live_channel_id: channel.id,
        live_channel_name: channel.name,
        live_channel_icon: channel.stream_icon
      }
    )
  end

  defp build_home_card(%{content_type: "movie"} = row) do
    %{
      id: row.id,
      progress_seconds: row.progress_seconds,
      duration_seconds: row.duration_seconds,
      watched_at: row.watched_at,
      content_type: row.content_type,
      content_id: row.movie_id,
      content_name: row.movie_name,
      content_icon: row.movie_icon
    }
  end

  defp build_home_card(%{content_type: "series"} = row) do
    %{
      id: row.id,
      progress_seconds: row.progress_seconds,
      duration_seconds: row.duration_seconds,
      watched_at: row.watched_at,
      content_type: row.content_type,
      content_id: row.series_id,
      content_name: row.series_name,
      content_icon: row.series_icon
    }
  end

  defp build_home_card(%{content_type: "episode"} = row) do
    %{
      id: row.id,
      progress_seconds: row.progress_seconds,
      duration_seconds: row.duration_seconds,
      watched_at: row.watched_at,
      content_type: row.content_type,
      content_id: row.episode_id,
      content_name: row.episode_name,
      content_icon: row.episode_icon
    }
  end

  defp build_home_card(%{content_type: "live_channel"} = row) do
    %{
      id: row.id,
      progress_seconds: row.progress_seconds,
      duration_seconds: row.duration_seconds,
      watched_at: row.watched_at,
      content_type: row.content_type,
      content_id: row.live_channel_id,
      content_name: row.live_channel_name,
      content_icon: row.live_channel_icon
    }
  end

  defp content_schema("live_channel"), do: Streamix.Iptv.LiveChannel
  defp content_schema("movie"), do: Streamix.Iptv.Movie
  defp content_schema("episode"), do: Streamix.Iptv.Episode
  defp content_schema("series"), do: Streamix.Iptv.Series
  defp content_schema(_), do: nil
end
