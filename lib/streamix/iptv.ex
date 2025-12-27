defmodule Streamix.Iptv do
  @moduledoc """
  The IPTV context - manages providers, live channels, movies, series, favorites, and watch history.
  """

  import Ecto.Query, warn: false

  alias Streamix.Repo

  alias Streamix.Iptv.{
    Category,
    Episode,
    Favorite,
    LiveChannel,
    Movie,
    Provider,
    Season,
    Series,
    Sync,
    TmdbClient,
    WatchHistory,
    XtreamClient
  }

  # =============================================================================
  # Providers
  # =============================================================================

  @doc """
  Lists providers owned by the user (excludes system providers).
  Use this for the provider management UI.
  """
  def list_providers(user_id) do
    Provider
    |> where(user_id: ^user_id)
    |> where([p], p.is_system == false)
    |> order_by(asc: :name)
    |> Repo.all()
  end

  @doc """
  Lists all providers visible to a user:
  - Global (is_system: true)
  - Public (visibility: :public)
  - User's own private providers (visibility: :private, user_id: user_id)
  """
  def list_visible_providers(user_id \\ nil) do
    Provider
    |> where([p], p.visibility in [:global, :public])
    |> or_where([p], p.user_id == ^user_id and p.visibility == :private)
    |> where([p], p.is_active == true)
    |> order_by(asc: :name)
    |> Repo.all()
  end

  @doc """
  Lists only public providers (global + public visibility).
  For unauthenticated users.
  """
  def list_public_providers do
    Provider
    |> where([p], p.visibility in [:global, :public])
    |> where([p], p.is_active == true)
    |> order_by(asc: :name)
    |> Repo.all()
  end

  def get_provider!(id), do: Repo.get!(Provider, id)
  def get_provider(id), do: Repo.get(Provider, id)

  def get_user_provider(user_id, provider_id) do
    Provider
    |> where(user_id: ^user_id, id: ^provider_id)
    |> Repo.one()
  end

  @doc """
  Gets a provider by ID if it's public or global.
  Used for guest access to public content.
  """
  def get_public_provider(provider_id) do
    Provider
    |> where(id: ^provider_id)
    |> where([p], p.visibility in [:global, :public])
    |> where([p], p.is_active == true)
    |> Repo.one()
  end

  @doc """
  Gets a provider by ID if user can access it.
  User can access: global, public, or their own providers.
  """
  def get_playable_provider(user_id, provider_id) do
    Provider
    |> where(id: ^provider_id)
    |> where([p], p.visibility in [:global, :public] or p.user_id == ^user_id)
    |> where([p], p.is_active == true)
    |> Repo.one()
  end

  def create_provider(attrs \\ %{}) do
    %Provider{}
    |> Provider.changeset(attrs)
    |> Repo.insert()
  end

  def update_provider(%Provider{} = provider, attrs) do
    provider
    |> Provider.changeset(attrs)
    |> Repo.update()
  end

  def delete_provider(%Provider{} = provider) do
    Repo.delete(provider)
  end

  def change_provider(%Provider{} = provider, attrs \\ %{}) do
    Provider.changeset(provider, attrs)
  end

  @doc """
  Tests connection to a provider.
  """
  def test_connection(url, username, password) do
    case XtreamClient.get_account_info(url, username, password) do
      {:ok, %{"user_info" => info}} -> {:ok, info}
      {:ok, info} -> {:ok, info}
      {:error, reason} -> {:error, reason}
    end
  end

  # =============================================================================
  # Categories
  # =============================================================================

  def list_categories(provider_id, type \\ nil) do
    query = Category |> where(provider_id: ^provider_id)
    query = if type, do: where(query, type: ^type), else: query
    query |> order_by(:name) |> Repo.all()
  end

  def get_category!(id), do: Repo.get!(Category, id)

  # =============================================================================
  # Live Channels
  # =============================================================================

  def list_live_channels(provider_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    search = Keyword.get(opts, :search)
    category_id = Keyword.get(opts, :category_id)

    query =
      LiveChannel
      |> where(provider_id: ^provider_id)
      |> order_by(:name)

    query =
      if search && search != "" do
        where(query, [c], ilike(c.name, ^"%#{search}%"))
      else
        query
      end

    query =
      if category_id do
        join(query, :inner, [c], lcc in "live_channel_categories",
          on: lcc.live_channel_id == c.id and lcc.category_id == ^category_id
        )
      else
        query
      end

    query
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  def count_live_channels(provider_id) do
    LiveChannel
    |> where(provider_id: ^provider_id)
    |> Repo.aggregate(:count)
  end

  def get_live_channel!(id), do: Repo.get!(LiveChannel, id)
  def get_live_channel(id), do: Repo.get(LiveChannel, id)
  def get_channel(id), do: get_live_channel(id)

  def get_user_live_channel(user_id, channel_id) do
    LiveChannel
    |> join(:inner, [c], p in Provider, on: c.provider_id == p.id)
    |> where([c, p], c.id == ^channel_id and p.user_id == ^user_id)
    |> preload(:provider)
    |> Repo.one()
  end

  @doc """
  Gets a live channel if visible to the user (global, public, or user's private).
  Use this for player access control.
  """
  def get_playable_channel(user_id, channel_id) do
    LiveChannel
    |> join(:inner, [c], p in Provider, on: c.provider_id == p.id)
    |> where([c, _p], c.id == ^channel_id)
    |> where([c, p], p.visibility in [:global, :public] or p.user_id == ^user_id)
    |> preload(:provider)
    |> Repo.one()
  end

  @doc """
  Gets a live channel from public providers only (for guests).
  """
  def get_public_channel(channel_id) do
    LiveChannel
    |> join(:inner, [c], p in Provider, on: c.provider_id == p.id)
    |> where([c, _p], c.id == ^channel_id)
    |> where([c, p], p.visibility in [:global, :public])
    |> preload(:provider)
    |> Repo.one()
  end

  def get_live_channel_with_provider!(id) do
    LiveChannel
    |> where(id: ^id)
    |> preload(:provider)
    |> Repo.one!()
  end

  # =============================================================================
  # Movies
  # =============================================================================

  def list_movies(provider_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    search = Keyword.get(opts, :search)
    category_id = Keyword.get(opts, :category_id)
    year = Keyword.get(opts, :year)

    query =
      Movie
      |> where(provider_id: ^provider_id)
      |> order_by(desc: :year, asc: :name)

    query =
      if search && search != "" do
        where(query, [m], ilike(m.name, ^"%#{search}%"))
      else
        query
      end

    query =
      if category_id do
        join(query, :inner, [m], mc in "movie_categories",
          on: mc.movie_id == m.id and mc.category_id == ^category_id
        )
      else
        query
      end

    query = if year, do: where(query, year: ^year), else: query

    query
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  def count_movies(provider_id) do
    Movie
    |> where(provider_id: ^provider_id)
    |> Repo.aggregate(:count)
  end

  def get_movie!(id), do: Repo.get!(Movie, id)
  def get_movie(id), do: Repo.get(Movie, id)

  def get_user_movie(user_id, movie_id) do
    Movie
    |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
    |> where([m, p], m.id == ^movie_id and p.user_id == ^user_id)
    |> preload(:provider)
    |> Repo.one()
  end

  @doc """
  Gets a movie if visible to the user (global, public, or user's private).
  Use this for player access control.
  """
  def get_playable_movie(user_id, movie_id) do
    Movie
    |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
    |> where([m, _p], m.id == ^movie_id)
    |> where([m, p], p.visibility in [:global, :public] or p.user_id == ^user_id)
    |> preload(:provider)
    |> Repo.one()
  end

  @doc """
  Gets a movie from public providers only (for guests).
  """
  def get_public_movie(movie_id) do
    Movie
    |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
    |> where([m, _p], m.id == ^movie_id)
    |> where([m, p], p.visibility in [:global, :public])
    |> preload(:provider)
    |> Repo.one()
  end

  def get_movie_with_provider!(id) do
    Movie
    |> where(id: ^id)
    |> preload(:provider)
    |> Repo.one!()
  end

  @doc """
  Fetches detailed movie info from Xtream API and TMDB (as fallback).
  Returns {:ok, updated_movie} or {:error, reason}.

  Flow:
  1. Fetch from Xtream API (get_vod_info)
  2. If still missing key data (plot, cast, director) and tmdb_id is available, fetch from TMDB
  3. Merge all data and update the movie record
  """
  def fetch_movie_info(%Movie{} = movie) do
    movie = Repo.preload(movie, :provider)
    provider = movie.provider

    # Step 1: Fetch from Xtream API
    xtream_attrs =
      case XtreamClient.get_vod_info(
             provider.url,
             provider.username,
             provider.password,
             movie.stream_id
           ) do
        {:ok, %{"info" => info, "movie_data" => movie_data}} ->
          parse_vod_info(info, movie_data)

        {:ok, %{"info" => info}} ->
          parse_vod_info(info, %{})

        _ ->
          %{}
      end

    # Step 2: Fetch from TMDB if we're still missing key data
    tmdb_id = xtream_attrs[:tmdb_id] || movie.tmdb_id
    tmdb_attrs = maybe_fetch_from_tmdb(movie, xtream_attrs, tmdb_id)

    # Step 3: Merge attrs (TMDB fills in what Xtream didn't provide)
    final_attrs = Map.merge(tmdb_attrs, xtream_attrs)

    update_movie(movie, final_attrs)
  end

  defp maybe_fetch_from_tmdb(movie, xtream_attrs, tmdb_id)
       when is_binary(tmdb_id) and tmdb_id != "" do
    if needs_tmdb_enrichment?(movie, xtream_attrs) do
      fetch_from_tmdb(tmdb_id)
    else
      %{}
    end
  end

  defp maybe_fetch_from_tmdb(_movie, _xtream_attrs, _tmdb_id), do: %{}

  defp needs_tmdb_enrichment?(movie, xtream_attrs) do
    missing_plot = is_nil(xtream_attrs[:plot]) and is_nil(movie.plot)
    missing_cast = is_nil(xtream_attrs[:cast]) and is_nil(movie.cast)
    missing_director = is_nil(xtream_attrs[:director]) and is_nil(movie.director)

    missing_plot or missing_cast or missing_director
  end

  defp fetch_from_tmdb(tmdb_id) do
    case TmdbClient.get_movie(tmdb_id) do
      {:ok, data} -> TmdbClient.parse_movie_response(data)
      _ -> %{}
    end
  end

  defp update_movie(movie, attrs) when attrs == %{}, do: {:ok, movie}

  defp update_movie(movie, attrs) do
    movie
    |> Movie.changeset(attrs)
    |> Repo.update()
  end

  defp parse_vod_info(info, movie_data) when is_map(info) do
    %{}
    |> maybe_put(:title, info["name"])
    |> maybe_put(:plot, info["plot"] || info["description"])
    |> maybe_put(:cast, info["cast"])
    |> maybe_put(:director, info["director"])
    |> maybe_put(:genre, info["genre"])
    |> maybe_put(:duration, info["duration"] || format_runtime(info["runtime"]))
    |> maybe_put(:duration_secs, parse_duration_secs(info["duration_secs"]))
    |> maybe_put(:rating, parse_decimal(info["rating"]))
    |> maybe_put(:rating_5based, parse_decimal(info["rating_5based"]))
    |> maybe_put(:year, parse_integer(info["releasedate"] || info["release_date"]))
    |> maybe_put(:tmdb_id, to_string_or_nil(info["tmdb_id"]))
    |> maybe_put(:imdb_id, info["kinopoisk_url"])
    |> maybe_put(:youtube_trailer, info["youtube_trailer"])
    |> maybe_put(:backdrop_path, parse_backdrop(info["backdrop_path"]))
    |> maybe_put(:stream_icon, info["cover_big"] || info["movie_image"])
    |> maybe_put(:container_extension, movie_data["container_extension"])
  end

  defp parse_vod_info(_, _), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_decimal(nil), do: nil
  defp parse_decimal(""), do: nil

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, _} -> decimal
      :error -> nil
    end
  end

  defp parse_decimal(value) when is_number(value), do: Decimal.from_float(value / 1)
  defp parse_decimal(_), do: nil

  defp parse_integer(nil), do: nil
  defp parse_integer(""), do: nil

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_integer(value) when is_integer(value), do: value
  defp parse_integer(_), do: nil

  defp parse_duration_secs(nil), do: nil
  defp parse_duration_secs(value) when is_integer(value), do: value
  defp parse_duration_secs(value) when is_binary(value), do: parse_integer(value)
  defp parse_duration_secs(_), do: nil

  defp format_runtime(nil), do: nil
  defp format_runtime(""), do: nil

  defp format_runtime(runtime) when is_binary(runtime) do
    case Integer.parse(runtime) do
      {minutes, _} when minutes > 0 ->
        hours = div(minutes, 60)
        mins = rem(minutes, 60)
        if hours > 0, do: "#{hours}h #{mins}min", else: "#{mins}min"

      _ ->
        runtime
    end
  end

  defp format_runtime(_), do: nil

  defp parse_backdrop(nil), do: nil
  defp parse_backdrop([]), do: nil
  defp parse_backdrop(paths) when is_list(paths), do: paths
  defp parse_backdrop(path) when is_binary(path), do: [path]
  defp parse_backdrop(_), do: nil

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(""), do: nil
  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(value) when is_integer(value), do: Integer.to_string(value)
  defp to_string_or_nil(_), do: nil

  # =============================================================================
  # Series
  # =============================================================================

  def list_series(provider_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    search = Keyword.get(opts, :search)
    category_id = Keyword.get(opts, :category_id)

    query =
      Series
      |> where(provider_id: ^provider_id)
      |> order_by(desc: :year, asc: :name)

    query =
      if search && search != "" do
        where(query, [s], ilike(s.name, ^"%#{search}%"))
      else
        query
      end

    query =
      if category_id do
        join(query, :inner, [s], sc in "series_categories",
          on: sc.series_id == s.id and sc.category_id == ^category_id
        )
      else
        query
      end

    query
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  def count_series(provider_id) do
    Series
    |> where(provider_id: ^provider_id)
    |> Repo.aggregate(:count)
  end

  def get_series!(id), do: Repo.get!(Series, id)
  def get_series(id), do: Repo.get(Series, id)

  def get_series_with_seasons(id) do
    seasons_query = from(s in Season, order_by: s.season_number)
    episodes_query = from(e in Episode, order_by: e.episode_num)

    Series
    |> where(id: ^id)
    |> preload(seasons: ^{seasons_query, episodes: episodes_query})
    |> preload(:provider)
    |> Repo.one()
  end

  def get_series_with_seasons!(id) do
    seasons_query = from(s in Season, order_by: s.season_number)
    episodes_query = from(e in Episode, order_by: e.episode_num)

    Series
    |> where(id: ^id)
    |> preload(seasons: ^{seasons_query, episodes: episodes_query})
    |> preload(:provider)
    |> Repo.one!()
  end

  @doc """
  Gets a series with seasons/episodes, syncing on-demand if needed.
  If the series has no episodes, syncs from the API first.
  Returns {:ok, series} or {:error, reason}.
  """
  def get_series_with_sync!(id) do
    series = get_series!(id)

    # Sync if no episodes yet
    if series.episode_count == 0 do
      case Sync.sync_series_details(series) do
        {:ok, _} -> :ok
        {:error, _reason} -> :ok
      end
    end

    # Return fresh data with preloads
    {:ok, get_series_with_seasons!(id)}
  end

  def get_episode!(id), do: Repo.get!(Episode, id)
  def get_episode(id), do: Repo.get(Episode, id)

  def get_user_episode(user_id, episode_id) do
    Episode
    |> join(:inner, [e], s in Season, on: e.season_id == s.id)
    |> join(:inner, [e, s], sr in Series, on: s.series_id == sr.id)
    |> join(:inner, [e, s, sr], p in Provider, on: sr.provider_id == p.id)
    |> where([e, s, sr, p], e.id == ^episode_id and p.user_id == ^user_id)
    |> preload(season: [series: :provider])
    |> Repo.one()
  end

  @doc """
  Gets an episode if visible to the user (global, public, or user's private).
  Use this for player access control.
  """
  def get_playable_episode(user_id, episode_id) do
    Episode
    |> join(:inner, [e], s in Season, on: e.season_id == s.id)
    |> join(:inner, [e, s], sr in Series, on: s.series_id == sr.id)
    |> join(:inner, [e, s, sr], p in Provider, on: sr.provider_id == p.id)
    |> where([e, _s, _sr, _p], e.id == ^episode_id)
    |> where([e, s, sr, p], p.visibility in [:global, :public] or p.user_id == ^user_id)
    |> preload(season: [series: :provider])
    |> Repo.one()
  end

  @doc """
  Gets an episode from public providers only (for guests).
  """
  def get_public_episode(episode_id) do
    Episode
    |> join(:inner, [e], s in Season, on: e.season_id == s.id)
    |> join(:inner, [e, s], sr in Series, on: s.series_id == sr.id)
    |> join(:inner, [e, s, sr], p in Provider, on: sr.provider_id == p.id)
    |> where([e, _s, _sr, _p], e.id == ^episode_id)
    |> where([e, s, sr, p], p.visibility in [:global, :public])
    |> preload(season: [series: :provider])
    |> Repo.one()
  end

  def get_episode_with_context!(id) do
    Episode
    |> where(id: ^id)
    |> preload(season: [series: :provider])
    |> Repo.one!()
  end

  # =============================================================================
  # Favorites (Polymorphic)
  # =============================================================================

  def list_favorites(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    content_type = Keyword.get(opts, :content_type)

    query =
      Favorite
      |> where(user_id: ^user_id)
      |> order_by(desc: :inserted_at)

    query = if content_type, do: where(query, content_type: ^content_type), else: query

    query
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  def favorite?(user_id, content_type, content_id) do
    Favorite
    |> where(user_id: ^user_id, content_type: ^content_type, content_id: ^content_id)
    |> Repo.exists?()
  end

  # Alias for consistency with LiveView naming conventions
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_favorite?(user_id, content_type, content_id),
    do: favorite?(user_id, content_type, content_id)

  def add_favorite(user_id, attrs) when is_map(attrs) do
    %Favorite{}
    |> Favorite.changeset(Map.merge(attrs, %{user_id: user_id}))
    |> Repo.insert()
  end

  def add_favorite(user_id, content_type, content_id, attrs \\ %{}) do
    %Favorite{}
    |> Favorite.changeset(
      Map.merge(attrs, %{
        user_id: user_id,
        content_type: content_type,
        content_id: content_id
      })
    )
    |> Repo.insert()
  end

  def remove_favorite(user_id, content_type, content_id) do
    {count, _} =
      Favorite
      |> where(user_id: ^user_id, content_type: ^content_type, content_id: ^content_id)
      |> Repo.delete_all()

    {:ok, count}
  end

  def toggle_favorite(user_id, content_type, content_id, attrs \\ %{}) do
    if favorite?(user_id, content_type, content_id) do
      remove_favorite(user_id, content_type, content_id)
      {:ok, :removed}
    else
      case add_favorite(user_id, content_type, content_id, attrs) do
        {:ok, _} -> {:ok, :added}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  # =============================================================================
  # Watch History (Polymorphic)
  # =============================================================================

  def list_watch_history(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    content_type = Keyword.get(opts, :content_type)

    query =
      WatchHistory
      |> where(user_id: ^user_id)
      |> order_by(desc: :watched_at)

    query = if content_type, do: where(query, content_type: ^content_type), else: query

    query
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  def add_watch_history(user_id, content_type, content_id, attrs \\ %{}) do
    %WatchHistory{}
    |> WatchHistory.changeset(
      Map.merge(attrs, %{
        user_id: user_id,
        content_type: content_type,
        content_id: content_id,
        watched_at: DateTime.utc_now()
      })
    )
    |> Repo.insert(
      on_conflict:
        {:replace, [:watched_at, :progress_seconds, :duration_seconds, :completed, :updated_at]},
      conflict_target: [:user_id, :content_type, :content_id]
    )
  end

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

    add_watch_history(user_id, content_type, content_id, attrs)
  end

  def clear_watch_history(user_id) do
    {count, _} =
      WatchHistory
      |> where(user_id: ^user_id)
      |> Repo.delete_all()

    {:ok, count}
  end

  def count_favorites(user_id) do
    Favorite
    |> where(user_id: ^user_id)
    |> Repo.aggregate(:count)
  end

  def remove_from_watch_history(user_id, entry_id) do
    WatchHistory
    |> where(user_id: ^user_id, id: ^entry_id)
    |> Repo.delete_all()
  end

  # Convenience aliases for PlayerLive
  def add_to_watch_history(user_id, attrs) when is_map(attrs) do
    add_watch_history(
      user_id,
      attrs[:content_type] || attrs["content_type"],
      attrs[:content_id] || attrs["content_id"],
      attrs
    )
  end

  def update_watch_progress(user_id, content_type, content_id, current_time, duration) do
    update_progress(user_id, content_type, content_id, round(current_time), round(duration))
  end

  def update_watch_time(user_id, content_type, content_id, duration_seconds) do
    add_watch_history(user_id, content_type, content_id, %{
      duration_seconds: round(duration_seconds)
    })
  end

  # =============================================================================
  # Search (across all user providers)
  # =============================================================================

  @doc """
  Searches channels across all visible providers (global + public + user's private).
  """
  def search_channels(user_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)

    LiveChannel
    |> join(:inner, [c], p in Provider, on: c.provider_id == p.id)
    |> where([c, p], p.visibility in [:global, :public] or p.user_id == ^user_id)
    |> where([c, _p], ilike(c.name, ^"%#{query}%"))
    |> order_by([c], asc: c.name)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Searches channels in public providers only (for guests).
  """
  def search_public_channels(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)

    LiveChannel
    |> join(:inner, [c], p in Provider, on: c.provider_id == p.id)
    |> where([c, p], p.visibility in [:global, :public])
    |> where([c, _p], ilike(c.name, ^"%#{query}%"))
    |> order_by([c], asc: c.name)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Searches movies across all visible providers (global + public + user's private).
  """
  def search_movies(user_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)

    Movie
    |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
    |> where([m, p], p.visibility in [:global, :public] or p.user_id == ^user_id)
    |> where([m, _p], ilike(m.name, ^"%#{query}%") or ilike(m.title, ^"%#{query}%"))
    |> order_by([m], desc: m.rating, asc: m.name)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Searches movies in public providers only (for guests).
  """
  def search_public_movies(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)

    Movie
    |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
    |> where([m, p], p.visibility in [:global, :public])
    |> where([m, _p], ilike(m.name, ^"%#{query}%") or ilike(m.title, ^"%#{query}%"))
    |> order_by([m], desc: m.rating, asc: m.name)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Searches series across all visible providers (global + public + user's private).
  """
  def search_series(user_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)

    Series
    |> join(:inner, [s], p in Provider, on: s.provider_id == p.id)
    |> where([s, p], p.visibility in [:global, :public] or p.user_id == ^user_id)
    |> where([s, _p], ilike(s.name, ^"%#{query}%") or ilike(s.title, ^"%#{query}%"))
    |> order_by([s], desc: s.rating, asc: s.name)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Searches series in public providers only (for guests).
  """
  def search_public_series(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 24)

    Series
    |> join(:inner, [s], p in Provider, on: s.provider_id == p.id)
    |> where([s, p], p.visibility in [:global, :public])
    |> where([s, _p], ilike(s.name, ^"%#{query}%") or ilike(s.title, ^"%#{query}%"))
    |> order_by([s], desc: s.rating, asc: s.name)
    |> limit(^limit)
    |> Repo.all()
  end

  # =============================================================================
  # Public Catalog (for homepage - all providers, no auth required)
  # =============================================================================

  @doc """
  Lists featured movies from public/global providers for public display.
  Orders by rating and recency.
  """
  def list_public_movies(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Movie
    |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
    |> where([m, p], p.visibility in [:global, :public])
    |> where([m, _p], not is_nil(m.stream_icon))
    |> order_by([m], desc: m.rating, desc: m.year, asc: m.name)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Lists featured series from public/global providers for public display.
  """
  def list_public_series(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Series
    |> join(:inner, [s], p in Provider, on: s.provider_id == p.id)
    |> where([s, p], p.visibility in [:global, :public])
    |> where([s, _p], not is_nil(s.cover))
    |> order_by([s], desc: s.rating, desc: s.year, asc: s.name)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Lists live channels from public/global providers for public display.
  """
  def list_public_channels(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    LiveChannel
    |> join(:inner, [c], p in Provider, on: c.provider_id == p.id)
    |> where([c, p], p.visibility in [:global, :public])
    |> where([c, _p], not is_nil(c.stream_icon))
    |> order_by([c], asc: c.name)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Gets a featured movie/series with backdrop for hero display.
  Uses a daily seed for consistency (same hero all day, changes at midnight).
  Only shows content from public/global providers.
  """
  def get_featured_content do
    # Daily seed for consistent hero throughout the day
    today = Date.utc_today()
    seed = Date.to_gregorian_days(today)

    # Try movies with backdrop first (from public/global providers)
    movies =
      Movie
      |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
      |> where([m, p], p.visibility in [:global, :public])
      |> where([m, _p], not is_nil(m.backdrop_path) and m.backdrop_path != ^[])
      |> where([m, _p], not is_nil(m.plot))
      |> order_by([m], desc: m.rating)
      |> limit(10)
      |> Repo.all()

    if movies != [] do
      index = rem(seed, length(movies))
      {:movie, Enum.at(movies, index)}
    else
      # Fallback to series with backdrop (from public/global providers)
      series_list =
        Series
        |> join(:inner, [s], p in Provider, on: s.provider_id == p.id)
        |> where([s, p], p.visibility in [:global, :public])
        |> where([s, _p], not is_nil(s.backdrop_path) and s.backdrop_path != ^[])
        |> where([s, _p], not is_nil(s.plot))
        |> order_by([s], desc: s.rating)
        |> limit(10)
        |> Repo.all()

      if series_list != [] do
        index = rem(seed, length(series_list))
        {:series, Enum.at(series_list, index)}
      else
        nil
      end
    end
  rescue
    _ -> nil
  end

  @doc """
  Gets total counts for public stats display.
  Only counts content from public/global providers.
  """
  def get_public_stats do
    channels_count =
      LiveChannel
      |> join(:inner, [c], p in Provider, on: c.provider_id == p.id)
      |> where([c, p], p.visibility in [:global, :public])
      |> Repo.aggregate(:count)

    movies_count =
      Movie
      |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
      |> where([m, p], p.visibility in [:global, :public])
      |> Repo.aggregate(:count)

    series_count =
      Series
      |> join(:inner, [s], p in Provider, on: s.provider_id == p.id)
      |> where([s, p], p.visibility in [:global, :public])
      |> Repo.aggregate(:count)

    %{
      channels_count: channels_count,
      movies_count: movies_count,
      series_count: series_count
    }
  end

  @doc """
  Lists movies by genre/category from public/global providers.
  """
  def list_public_movies_by_genre(genre, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Movie
    |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
    |> where([m, p], p.visibility in [:global, :public])
    |> where([m, _p], ilike(m.genre, ^"%#{genre}%"))
    |> where([m, _p], not is_nil(m.stream_icon))
    |> order_by([m], desc: m.rating, desc: m.year)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Gets recently added content from public/global providers.
  """
  def list_recently_added(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    movies =
      Movie
      |> join(:inner, [m], p in Provider, on: m.provider_id == p.id)
      |> where([m, p], p.visibility in [:global, :public])
      |> where([m, _p], not is_nil(m.stream_icon))
      |> order_by([m], desc: m.inserted_at)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.map(&{:movie, &1})

    series =
      Series
      |> join(:inner, [s], p in Provider, on: s.provider_id == p.id)
      |> where([s, p], p.visibility in [:global, :public])
      |> where([s, _p], not is_nil(s.cover))
      |> order_by([s], desc: s.inserted_at)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.map(&{:series, &1})

    (movies ++ series)
    |> Enum.sort_by(fn {_type, item} -> item.inserted_at end, {:desc, DateTime})
    |> Enum.take(limit)
  end

  # =============================================================================
  # Sync Operations
  # =============================================================================

  def sync_provider(provider, opts \\ []) do
    Sync.sync_all(provider, opts)
  end

  def async_sync_provider(provider) do
    Task.start(fn ->
      Phoenix.PubSub.broadcast(
        Streamix.PubSub,
        "user:#{provider.user_id}:providers",
        {:sync_status, %{provider_id: provider.id, status: "syncing"}}
      )

      Phoenix.PubSub.broadcast(
        Streamix.PubSub,
        "provider:#{provider.id}",
        {:sync_status, %{status: "syncing"}}
      )

      case Sync.sync_all(provider) do
        {:ok, result} ->
          # Reload provider to get updated counts
          updated_provider = get_provider!(provider.id)

          Phoenix.PubSub.broadcast(
            Streamix.PubSub,
            "user:#{provider.user_id}:providers",
            {:sync_status,
             %{
               provider_id: provider.id,
               status: "completed",
               live_count: updated_provider.live_count,
               movies_count: updated_provider.movies_count,
               series_count: updated_provider.series_count
             }}
          )

          Phoenix.PubSub.broadcast(
            Streamix.PubSub,
            "provider:#{provider.id}",
            {:sync_status,
             %{
               status: "completed",
               live_count: updated_provider.live_count,
               movies_count: updated_provider.movies_count,
               series_count: updated_provider.series_count
             }}
          )

          {:ok, result}

        {:error, reason} ->
          Phoenix.PubSub.broadcast(
            Streamix.PubSub,
            "user:#{provider.user_id}:providers",
            {:sync_status, %{provider_id: provider.id, status: "failed", error: reason}}
          )

          Phoenix.PubSub.broadcast(
            Streamix.PubSub,
            "provider:#{provider.id}",
            {:sync_status, %{status: "failed", error: reason}}
          )

          {:error, reason}
      end
    end)
  end
end
