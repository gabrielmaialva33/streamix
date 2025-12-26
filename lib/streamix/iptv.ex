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
    WatchHistory,
    XtreamClient
  }

  # =============================================================================
  # Providers
  # =============================================================================

  def list_providers(user_id) do
    Provider
    |> where(user_id: ^user_id)
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

  def get_movie_with_provider!(id) do
    Movie
    |> where(id: ^id)
    |> preload(:provider)
    |> Repo.one!()
  end

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
      case Streamix.Iptv.Sync.sync_series_details(series) do
        {:ok, _} -> :ok
        {:error, _reason} -> :ok
      end
    end

    # Return fresh data with preloads
    {:ok, get_series_with_seasons!(id)}
  end

  def get_episode!(id), do: Repo.get!(Episode, id)

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

  # =============================================================================
  # Sync Operations
  # =============================================================================

  alias Streamix.Iptv.Sync

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
