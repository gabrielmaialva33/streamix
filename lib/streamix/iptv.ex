defmodule Streamix.Iptv do
  @moduledoc """
  The IPTV context - manages providers, channels, favorites, and watch history.

  This module follows consistent error handling patterns:
  - Returns `{:ok, result}` on success
  - Returns `{:error, reason}` on failure where reason is an atom or tuple
  - Bang functions raise on failure

  All functions that access user data require `user_id` as first argument
  for proper scoping and authorization.
  """

  import Ecto.Query, warn: false

  alias Streamix.Cache
  alias Streamix.Iptv.{Channel, ChannelQuery, Client, Favorite, Provider, WatchHistory}
  alias Streamix.Repo
  alias Streamix.Workers.SyncProviderWorker

  # Configuration with defaults
  @config Application.compile_env(:streamix, __MODULE__, [])
  defp config(key, default), do: Keyword.get(@config, key, default)

  defp sync_batch_size, do: config(:sync_batch_size, 500)
  defp sync_timeout, do: config(:sync_timeout, :timer.minutes(10))
  defp cache_ttl, do: config(:cache_ttl, 3600)
  defp default_page_size, do: config(:default_page_size, 100)
  defp max_page_size, do: config(:max_page_size, 500)

  # =============================================================================
  # Type specifications
  # =============================================================================

  @type user_id :: integer()
  @type provider_id :: integer()
  @type channel_id :: integer()
  @type pagination_opts :: [limit: pos_integer(), offset: non_neg_integer()]
  @type filter_opts :: [
          {:limit, pos_integer()}
          | {:offset, non_neg_integer()}
          | {:group, String.t() | nil}
          | {:search, String.t() | nil}
        ]
  @type sync_error :: :not_found | :already_syncing | :fetch_failed | term()
  @type connection_error ::
          :invalid_credentials
          | :invalid_url
          | :host_not_found
          | :connection_refused
          | :timeout
          | :invalid_response
          | {:http_error, integer()}

  # =============================================================================
  # Providers
  # =============================================================================

  @doc """
  Lists all providers for a user, ordered by name.
  """
  @spec list_providers(user_id()) :: [Provider.t()]
  def list_providers(user_id) do
    Provider
    |> where(user_id: ^user_id)
    |> order_by(asc: :name)
    |> Repo.all()
  end

  @doc """
  Gets a provider by ID. Raises if not found.
  """
  @spec get_provider!(provider_id()) :: Provider.t()
  def get_provider!(id), do: Repo.get!(Provider, id)

  @doc """
  Gets a provider by ID. Returns nil if not found.
  """
  @spec get_provider(provider_id()) :: Provider.t() | nil
  def get_provider(id), do: Repo.get(Provider, id)

  @doc """
  Gets a provider belonging to a specific user.
  Returns nil if not found or doesn't belong to user.
  """
  @spec get_user_provider(user_id(), provider_id()) :: Provider.t() | nil
  def get_user_provider(user_id, provider_id) do
    Provider
    |> where(user_id: ^user_id, id: ^provider_id)
    |> Repo.one()
  end

  @doc """
  Creates a new provider.
  """
  @spec create_provider(map()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def create_provider(attrs \\ %{}) do
    %Provider{}
    |> Provider.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Validates provider credentials before creating.
  Tests connection and returns account info on success.

  Returns:
  - `{:ok, provider, account_info}` on success
  - `{:error, :validation, changeset}` for validation errors
  - `{:error, :connection, reason}` for connection errors
  """
  @spec create_provider_with_validation(map()) ::
          {:ok, Provider.t(), map()}
          | {:error, :validation, Ecto.Changeset.t()}
          | {:error, :connection, connection_error()}
  def create_provider_with_validation(attrs) do
    changeset = Provider.changeset(%Provider{}, attrs)

    with {:valid, true} <- {:valid, changeset.valid?},
         url = Ecto.Changeset.get_field(changeset, :url),
         username = Ecto.Changeset.get_field(changeset, :username),
         password = Ecto.Changeset.get_field(changeset, :password),
         {:connection, {:ok, account_info}} <-
           {:connection, Client.test_connection(url, username, password)},
         {:insert, {:ok, provider}} <- {:insert, Repo.insert(changeset)} do
      {:ok, provider, account_info}
    else
      {:valid, false} -> {:error, :validation, changeset}
      {:insert, {:error, changeset}} -> {:error, :validation, changeset}
      {:connection, {:error, reason}} -> {:error, :connection, reason}
    end
  end

  @doc """
  Tests connection to a provider without creating it.
  Useful for validating credentials in forms.
  """
  @spec test_provider_connection(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, connection_error()}
  def test_provider_connection(url, username, password) do
    Client.test_connection(url, username, password)
  end

  @doc """
  Returns a human-readable error message for connection errors.
  """
  @spec connection_error_message(connection_error()) :: String.t()
  def connection_error_message(:invalid_credentials), do: "Invalid username or password"
  def connection_error_message(:invalid_url), do: "Invalid server URL"
  def connection_error_message(:host_not_found), do: "Server not found - check the URL"
  def connection_error_message(:connection_refused), do: "Connection refused by server"
  def connection_error_message(:timeout), do: "Connection timed out - server may be slow"
  def connection_error_message(:invalid_response), do: "Invalid response from server"
  def connection_error_message({:http_error, status}), do: "HTTP error: #{status}"
  def connection_error_message(_), do: "Failed to connect to server"

  @doc """
  Updates a provider.
  """
  @spec update_provider(Provider.t(), map()) ::
          {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def update_provider(%Provider{} = provider, attrs) do
    provider
    |> Provider.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a provider and all associated data.
  """
  @spec delete_provider(Provider.t()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def delete_provider(%Provider{} = provider) do
    Repo.delete(provider)
  end

  @doc """
  Returns a changeset for tracking provider changes.
  """
  @spec change_provider(Provider.t(), map()) :: Ecto.Changeset.t()
  def change_provider(%Provider{} = provider, attrs \\ %{}) do
    Provider.changeset(provider, attrs)
  end

  # =============================================================================
  # Provider Sync
  # =============================================================================

  @doc """
  Syncs channels from a provider by fetching and parsing the M3U playlist.
  Uses a transaction to ensure atomicity - either all channels are replaced or none.

  This is a blocking operation. For async sync, use `async_sync_provider/1`.
  """
  @spec sync_provider(Provider.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sync_provider(%Provider{} = provider) do
    case Client.get_channels(provider.url, provider.username, provider.password) do
      {:ok, channels} ->
        perform_sync(provider, channels)

      {:error, reason} ->
        {:error, {:fetch_failed, reason}}
    end
  end

  @doc """
  Syncs a provider asynchronously using Oban background job.
  Returns `{:ok, job}` or `{:error, changeset}`.
  """
  @spec sync_provider_async(Provider.t()) :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def sync_provider_async(%Provider{} = provider) do
    Streamix.Workers.SyncProviderWorker.enqueue(provider)
  end

  defp perform_sync(provider, channels) do
    now_naive = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    now_utc = DateTime.utc_now() |> DateTime.truncate(:second)

    channel_attrs =
      Enum.map(channels, fn ch ->
        %{
          name: ch.name,
          logo_url: ch.logo_url,
          stream_url: ch.stream_url,
          tvg_id: ch.tvg_id,
          tvg_name: ch.tvg_name,
          group_title: ch.group_title,
          provider_id: provider.id,
          inserted_at: now_naive,
          updated_at: now_naive
        }
      end)

    result =
      Repo.transaction(
        fn ->
          delete_provider_channels(provider.id)
          insert_channels_in_batches(channel_attrs)
        end,
        timeout: sync_timeout()
      )

    case result do
      {:ok, count} ->
        finalize_sync(provider, count, now_utc)
        {:ok, count}

      {:error, reason} ->
        {:error, {:transaction_failed, reason}}
    end
  end

  defp delete_provider_channels(provider_id) do
    Channel
    |> where(provider_id: ^provider_id)
    |> Repo.delete_all()
  end

  defp insert_channels_in_batches(channel_attrs) do
    channel_attrs
    |> Enum.chunk_every(sync_batch_size())
    |> Enum.reduce(0, fn batch, acc ->
      {inserted, _} = Repo.insert_all(Channel, batch)
      acc + inserted
    end)
  end

  defp finalize_sync(provider, count, timestamp) do
    update_provider(provider, %{
      last_synced_at: timestamp,
      channels_count: count,
      sync_status: "completed"
    })

    invalidate_provider_cache(provider)
  end

  defp invalidate_provider_cache(provider) do
    Cache.invalidate_provider(provider.id)
    Cache.invalidate_user(provider.user_id)
  end

  @doc """
  Enqueues a background job to sync the provider's channels.
  Returns immediately, sync happens asynchronously.
  Use PubSub to subscribe to sync status updates.
  """
  @spec async_sync_provider(Provider.t() | provider_id()) ::
          {:ok, Oban.Job.t()} | {:error, :not_found | term()}
  def async_sync_provider(%Provider{} = provider) do
    with {:ok, _} <- update_provider(provider, %{sync_status: "pending"}) do
      SyncProviderWorker.enqueue(provider)
    end
  end

  def async_sync_provider(provider_id) when is_integer(provider_id) do
    case get_provider(provider_id) do
      nil -> {:error, :not_found}
      provider -> async_sync_provider(provider)
    end
  end

  # =============================================================================
  # Public Catalog (no authentication required)
  # =============================================================================

  @doc """
  Lists all channels from all active providers (public catalog).
  Does not require authentication.

  ## Options
    * `:limit` - Maximum number of results (default: 100)
    * `:offset` - Number of results to skip (default: 0)
    * `:group` - Filter by group_title
    * `:search` - Search by channel name (case-insensitive)
  """
  @spec list_all_channels(filter_opts()) :: [Channel.t()]
  def list_all_channels(opts \\ []) do
    opts = normalize_pagination_opts(opts)

    Channel
    |> join(:inner, [c], p in Provider, on: c.provider_id == p.id)
    |> where([c, p], p.is_active == true)
    |> ChannelQuery.apply_filters(opts)
    |> Repo.all()
  end

  @doc """
  Counts all channels from active providers (public catalog).
  """
  @spec count_all_channels(keyword()) :: non_neg_integer()
  def count_all_channels(opts \\ []) do
    query =
      Channel
      |> join(:inner, [c], p in Provider, on: c.provider_id == p.id)
      |> where([c, p], p.is_active == true)

    query =
      case opts[:group] do
        nil -> query
        "" -> query
        group -> where(query, [c], c.group_title == ^group)
      end

    query =
      case opts[:search] do
        nil ->
          query

        "" ->
          query

        search ->
          search_term = "%#{search}%"
          where(query, [c], ilike(fragment("LEFT(?, 255)", c.name), ^search_term))
      end

    Repo.aggregate(query, :count)
  end

  @doc """
  Lists all distinct categories from all active providers (public catalog).
  """
  @spec list_all_categories() :: [String.t()]
  def list_all_categories do
    Channel
    |> join(:inner, [c], p in Provider, on: c.provider_id == p.id)
    |> where([c, p], p.is_active == true)
    |> ChannelQuery.distinct_groups()
    |> Repo.all()
  end

  # =============================================================================
  # Channels
  # =============================================================================

  @doc """
  Lists channels for a provider with optional filtering and pagination.

  ## Options
    * `:limit` - Maximum number of results (default: #{inspect(@config[:default_page_size] || 100)})
    * `:offset` - Number of results to skip (default: 0)
    * `:group` - Filter by group_title
    * `:search` - Search by channel name (case-insensitive)
  """
  @spec list_channels(provider_id(), filter_opts()) :: [Channel.t()]
  def list_channels(provider_id, opts \\ []) do
    opts = normalize_pagination_opts(opts)

    Channel
    |> ChannelQuery.for_provider(provider_id)
    |> ChannelQuery.apply_filters(opts)
    |> Repo.all()
  end

  @doc """
  Lists channels from all active providers belonging to a user.
  Applies the same filtering options as `list_channels/2`.
  """
  @spec list_user_channels(user_id(), filter_opts()) :: [Channel.t()]
  def list_user_channels(user_id, opts \\ []) do
    opts = normalize_pagination_opts(opts)

    Channel
    |> ChannelQuery.for_user(user_id)
    |> ChannelQuery.apply_filters(opts)
    |> Repo.all()
  end

  defp normalize_pagination_opts(opts) do
    limit = opts[:limit] || default_page_size()
    limit = min(limit, max_page_size())
    offset = opts[:offset] || 0

    Keyword.merge(opts, limit: limit, offset: offset)
  end

  @doc """
  Gets a channel by ID. Raises if not found.
  """
  @spec get_channel!(channel_id()) :: Channel.t()
  def get_channel!(id), do: Repo.get!(Channel, id)

  @doc """
  Gets a channel by ID. Returns nil if not found.
  """
  @spec get_channel(channel_id()) :: Channel.t() | nil
  def get_channel(id), do: Repo.get(Channel, id)

  @doc """
  Gets distinct category names for a provider.
  Results are cached for performance.
  """
  @spec get_categories(provider_id()) :: [String.t()]
  def get_categories(provider_id) do
    Cache.fetch(Cache.provider_categories_key(provider_id), cache_ttl(), fn ->
      Channel
      |> ChannelQuery.for_provider(provider_id)
      |> ChannelQuery.distinct_groups()
      |> Repo.all()
    end)
  end

  @doc """
  Gets distinct category names from all active providers belonging to a user.
  Results are cached for performance.
  """
  @spec get_user_categories(user_id()) :: [String.t()]
  def get_user_categories(user_id) do
    Cache.fetch(Cache.categories_key(user_id), cache_ttl(), fn ->
      Channel
      |> ChannelQuery.for_user(user_id)
      |> ChannelQuery.distinct_groups()
      |> Repo.all()
    end)
  end

  @doc """
  Alias for get_user_categories/1 for consistency.
  """
  @spec list_categories(user_id()) :: [String.t()]
  def list_categories(user_id), do: get_user_categories(user_id)

  @doc """
  Lists channels in the same group as the given channel.
  Useful for showing related channels in the player.
  """
  @spec list_channels_by_group(provider_id(), String.t() | nil, keyword()) :: [Channel.t()]
  def list_channels_by_group(provider_id, group_title, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Channel
    |> where(provider_id: ^provider_id)
    |> where(
      [c],
      c.group_title == ^group_title or (is_nil(^group_title) and is_nil(c.group_title))
    )
    |> order_by([c], c.name)
    |> limit(^limit)
    |> Repo.all()
  end

  # =============================================================================
  # Favorites
  # =============================================================================

  @doc """
  Lists favorites for a user with pagination.

  ## Options
    * `:limit` - Maximum number of results (default: 100)
    * `:offset` - Number of results to skip (default: 0)
  """
  @spec list_favorites(user_id(), pagination_opts()) :: [Favorite.t()]
  def list_favorites(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, default_page_size())
    offset = Keyword.get(opts, :offset, 0)

    Favorite
    |> where(user_id: ^user_id)
    |> join(:inner, [f], c in Channel, on: f.channel_id == c.id)
    |> preload([f, c], channel: c)
    |> order_by([f], desc: f.inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Returns the total count of favorites for a user.
  """
  @spec count_favorites(user_id()) :: non_neg_integer()
  def count_favorites(user_id) do
    Favorite
    |> where(user_id: ^user_id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Checks if a channel is favorited by a user.
  """
  @spec favorite?(user_id(), channel_id()) :: boolean()
  def favorite?(user_id, channel_id) do
    Favorite
    |> where(user_id: ^user_id, channel_id: ^channel_id)
    |> Repo.exists?()
  end

  @doc """
  Adds a channel to user's favorites.
  """
  @spec add_favorite(user_id(), channel_id()) ::
          {:ok, Favorite.t()} | {:error, Ecto.Changeset.t()}
  def add_favorite(user_id, channel_id) do
    %Favorite{}
    |> Favorite.changeset(%{user_id: user_id, channel_id: channel_id})
    |> Repo.insert()
  end

  @doc """
  Removes a channel from user's favorites.
  Returns the number of deleted records.
  """
  @spec remove_favorite(user_id(), channel_id()) :: {:ok, non_neg_integer()}
  def remove_favorite(user_id, channel_id) do
    {count, _} =
      Favorite
      |> where(user_id: ^user_id, channel_id: ^channel_id)
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc """
  Toggles favorite status for a channel.
  Returns `{:ok, :added}` or `{:ok, :removed}`.
  """
  @spec toggle_favorite(user_id(), channel_id()) ::
          {:ok, :added | :removed} | {:error, Ecto.Changeset.t()}
  def toggle_favorite(user_id, channel_id) do
    if favorite?(user_id, channel_id) do
      remove_favorite(user_id, channel_id)
      {:ok, :removed}
    else
      case add_favorite(user_id, channel_id) do
        {:ok, _} -> {:ok, :added}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  # =============================================================================
  # Watch History
  # =============================================================================

  @doc """
  Lists watch history for a user with pagination.

  ## Options
    * `:limit` - Maximum number of results (default: 50)
    * `:offset` - Number of results to skip (default: 0)
  """
  @spec list_watch_history(user_id(), pagination_opts()) :: [WatchHistory.t()]
  def list_watch_history(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    WatchHistory
    |> where(user_id: ^user_id)
    |> join(:inner, [h], c in Channel, on: h.channel_id == c.id)
    |> preload([h, c], channel: c)
    |> order_by([h], desc: h.watched_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Adds a watch history entry.
  """
  @spec add_watch_history(user_id(), channel_id(), non_neg_integer()) ::
          {:ok, WatchHistory.t()} | {:error, Ecto.Changeset.t()}
  def add_watch_history(user_id, channel_id, duration_seconds \\ 0) do
    %WatchHistory{}
    |> WatchHistory.changeset(%{
      user_id: user_id,
      channel_id: channel_id,
      watched_at: DateTime.utc_now(),
      duration_seconds: duration_seconds
    })
    |> Repo.insert()
  end

  @doc """
  Clears all watch history for a user.
  Returns the number of deleted records.
  """
  @spec clear_watch_history(user_id()) :: {:ok, non_neg_integer()}
  def clear_watch_history(user_id) do
    {count, _} =
      WatchHistory
      |> where(user_id: ^user_id)
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc """
  Prunes old watch history entries, keeping only the most recent ones.
  """
  @spec prune_watch_history(user_id(), pos_integer()) :: {:ok, non_neg_integer()}
  def prune_watch_history(user_id, keep_count \\ 100) do
    subquery =
      WatchHistory
      |> where(user_id: ^user_id)
      |> order_by(desc: :watched_at)
      |> limit(^keep_count)
      |> select([h], h.id)

    {count, _} =
      WatchHistory
      |> where(user_id: ^user_id)
      |> where([h], h.id not in subquery(subquery))
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc """
  Returns the total watch time in seconds for a user.
  """
  @spec total_watch_time(user_id()) :: non_neg_integer()
  def total_watch_time(user_id) do
    WatchHistory
    |> where(user_id: ^user_id)
    |> Repo.aggregate(:sum, :duration_seconds) || 0
  end
end
