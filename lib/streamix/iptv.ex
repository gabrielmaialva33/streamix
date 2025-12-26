defmodule Streamix.Iptv do
  @moduledoc """
  The IPTV context - manages providers, channels, favorites, and watch history.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{Channel, Client, Favorite, Provider, WatchHistory}
  alias Streamix.Repo
  alias Streamix.Workers.SyncProviderWorker

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

  @doc """
  Validates provider credentials before creating.
  Tests connection and returns account info on success.

  Returns:
  - {:ok, provider, account_info} on success
  - {:error, :validation, changeset} for validation errors
  - {:error, :connection, reason} for connection errors
  """
  def create_provider_with_validation(attrs) do
    changeset = Provider.changeset(%Provider{}, attrs)

    with true <- changeset.valid?,
         url = Ecto.Changeset.get_field(changeset, :url),
         username = Ecto.Changeset.get_field(changeset, :username),
         password = Ecto.Changeset.get_field(changeset, :password),
         {:ok, account_info} <- Client.test_connection(url, username, password),
         {:ok, provider} <- Repo.insert(changeset) do
      {:ok, provider, account_info}
    else
      false -> {:error, :validation, changeset}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, :validation, changeset}
      {:error, reason} -> {:error, :connection, reason}
    end
  end

  @doc """
  Tests connection to a provider without creating it.
  Useful for validating credentials in forms.
  """
  def test_provider_connection(url, username, password) do
    Client.test_connection(url, username, password)
  end

  @doc """
  Returns a human-readable error message for connection errors.
  """
  def connection_error_message(:invalid_credentials), do: "Invalid username or password"
  def connection_error_message(:invalid_url), do: "Invalid server URL"
  def connection_error_message(:host_not_found), do: "Server not found - check the URL"
  def connection_error_message(:connection_refused), do: "Connection refused by server"
  def connection_error_message(:timeout), do: "Connection timed out - server may be slow"
  def connection_error_message(:invalid_response), do: "Invalid response from server"
  def connection_error_message(_), do: "Failed to connect to server"

  def update_provider(%Provider{} = provider, attrs) do
    provider
    |> Provider.changeset(attrs)
    |> Repo.update()
  end

  def delete_provider(%Provider{} = provider) do
    Repo.delete(provider)
  end

  @doc """
  Syncs channels from a provider by fetching and parsing the M3U playlist.
  Uses a transaction to ensure atomicity - either all channels are replaced or none.
  """
  def sync_provider(%Provider{} = provider) do
    with {:ok, channels} <-
           Client.get_channels(provider.url, provider.username, provider.password) do
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

      # Wrap delete + insert in transaction for atomicity
      result =
        Repo.transaction(
          fn ->
            # Delete existing channels
            Channel
            |> where(provider_id: ^provider.id)
            |> Repo.delete_all()

            # Insert in batches of 500
            channel_attrs
            |> Enum.chunk_every(500)
            |> Enum.reduce(0, fn batch, acc ->
              {inserted, _} = Repo.insert_all(Channel, batch)
              acc + inserted
            end)
          end,
          timeout: :infinity
        )

      case result do
        {:ok, count} ->
          # Update provider (outside transaction - ok if this fails)
          update_provider(provider, %{
            last_synced_at: now_utc,
            channels_count: count
          })

          # Invalidate cache
          Streamix.Cache.invalidate_provider(provider.id)
          Streamix.Cache.invalidate_user(provider.user_id)

          {:ok, count}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Enqueues a background job to sync the provider's channels.
  Returns immediately, sync happens asynchronously.
  Use PubSub to subscribe to sync status updates.
  """
  def async_sync_provider(%Provider{} = provider) do
    update_provider(provider, %{sync_status: "pending"})
    SyncProviderWorker.enqueue(provider)
  end

  def async_sync_provider(provider_id) do
    case get_provider(provider_id) do
      nil -> {:error, :not_found}
      provider -> async_sync_provider(provider)
    end
  end

  # =============================================================================
  # Channels
  # =============================================================================

  def list_channels(provider_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    group = Keyword.get(opts, :group)
    search = Keyword.get(opts, :search)

    query =
      Channel
      |> where(provider_id: ^provider_id)
      |> order_by(asc: :group_title, asc: :name)

    query = if group, do: where(query, group_title: ^group), else: query

    query =
      if search do
        search_term = "%#{search}%"
        where(query, [c], ilike(c.name, ^search_term))
      else
        query
      end

    query
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  def list_user_channels(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    group = Keyword.get(opts, :group)
    search = Keyword.get(opts, :search)

    query =
      Channel
      |> join(:inner, [c], p in Provider, on: c.provider_id == p.id)
      |> where([c, p], p.user_id == ^user_id and p.is_active == true)
      |> order_by([c], asc: c.group_title, asc: c.name)

    query = if group, do: where(query, [c], c.group_title == ^group), else: query

    query =
      if search do
        search_term = "%#{search}%"
        where(query, [c], ilike(c.name, ^search_term))
      else
        query
      end

    query
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  def get_channel!(id), do: Repo.get!(Channel, id)

  def get_channel(id), do: Repo.get(Channel, id)

  def get_categories(provider_id) do
    alias Streamix.Cache

    Cache.fetch(Cache.provider_categories_key(provider_id), 3600, fn ->
      Channel
      |> where(provider_id: ^provider_id)
      |> select([c], c.group_title)
      |> distinct(true)
      |> order_by(asc: :group_title)
      |> Repo.all()
      |> Enum.reject(&is_nil/1)
    end)
  end

  def get_user_categories(user_id) do
    alias Streamix.Cache

    Cache.fetch(Cache.categories_key(user_id), 3600, fn ->
      Channel
      |> join(:inner, [c], p in Provider, on: c.provider_id == p.id)
      |> where([c, p], p.user_id == ^user_id and p.is_active == true)
      |> select([c], c.group_title)
      |> distinct(true)
      |> order_by(asc: :group_title)
      |> Repo.all()
      |> Enum.reject(&is_nil/1)
    end)
  end

  # =============================================================================
  # Favorites
  # =============================================================================

  def list_favorites(user_id) do
    Favorite
    |> where(user_id: ^user_id)
    |> join(:inner, [f], c in Channel, on: f.channel_id == c.id)
    |> preload([f, c], channel: c)
    |> order_by([f], desc: f.inserted_at)
    |> Repo.all()
  end

  def favorite?(user_id, channel_id) do
    Favorite
    |> where(user_id: ^user_id, channel_id: ^channel_id)
    |> Repo.exists?()
  end

  def add_favorite(user_id, channel_id) do
    %Favorite{}
    |> Favorite.changeset(%{user_id: user_id, channel_id: channel_id})
    |> Repo.insert()
  end

  def remove_favorite(user_id, channel_id) do
    Favorite
    |> where(user_id: ^user_id, channel_id: ^channel_id)
    |> Repo.delete_all()
  end

  def toggle_favorite(user_id, channel_id) do
    if favorite?(user_id, channel_id) do
      remove_favorite(user_id, channel_id)
      {:ok, :removed}
    else
      case add_favorite(user_id, channel_id) do
        {:ok, _} -> {:ok, :added}
        {:error, _} = error -> error
      end
    end
  end

  # =============================================================================
  # Watch History
  # =============================================================================

  def list_watch_history(user_id, limit \\ 50) do
    WatchHistory
    |> where(user_id: ^user_id)
    |> join(:inner, [h], c in Channel, on: h.channel_id == c.id)
    |> preload([h, c], channel: c)
    |> order_by([h], desc: h.watched_at)
    |> limit(^limit)
    |> Repo.all()
  end

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

  def clear_watch_history(user_id) do
    WatchHistory
    |> where(user_id: ^user_id)
    |> Repo.delete_all()
  end
end
