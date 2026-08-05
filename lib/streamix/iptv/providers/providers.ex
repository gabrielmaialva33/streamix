defmodule Streamix.Iptv.Providers do
  @moduledoc """
  Provider operations.

  Provides CRUD operations and retrieval of IPTV providers
  with proper access control based on visibility settings.
  """

  import Ecto.Query, warn: false

  alias Streamix.Billing
  alias Streamix.Cache
  alias Streamix.Iptv.{Provider, Sync, XtreamClient}
  alias Streamix.Repo
  alias Streamix.Workers.{SyncGindexProviderWorker, SyncProviderWorker}

  # L1-only (provider structs carry decrypted credentials — never Redis).
  # Short TTL bounds cross-node staleness; writes below invalidate this
  # node eagerly.
  @global_provider_cache_key {:providers, :global}
  @global_provider_cache_ttl :timer.seconds(60)

  @type gindex_drive :: %{kind: String.t(), metadata: map()}
  @type gindex_sync_source :: %{
          provider_id: pos_integer(),
          name: String.t(),
          base_url: String.t(),
          drives: [gindex_drive()]
        }

  @gindex_sync_fields ~w(sync_status movies_count series_count vod_synced_at series_synced_at)a

  # =============================================================================
  # Listing
  # =============================================================================

  @doc """
  Lists providers owned by the user (excludes system providers).
  Use this for the provider management UI.

  Pass `scope: :all` to bypass the ownership/system filter — used by
  admin views that need to surface every provider, including global
  system rows that regular users shouldn't see.
  """
  @spec list(integer(), keyword()) :: [Provider.t()]
  def list(user_id, opts \\ []) do
    case Keyword.get(opts, :scope, :user) do
      :all ->
        Provider
        |> order_by(asc: :is_system, asc: :name)
        |> Repo.all()

      :user ->
        Provider
        |> where(user_id: ^user_id)
        |> where([p], p.is_system == false)
        |> order_by(asc: :name)
        |> Repo.all()
    end
  end

  @doc """
  Lists personal Xtream providers eligible for the periodic sync dispatcher.

  System providers and source adapters such as GIndex and Torrent have their
  own schedulers and must not enter the Xtream worker.
  """
  @spec list_personal_xtream() :: [Provider.t()]
  def list_personal_xtream do
    Provider
    |> where([p], p.provider_type == :xtream and p.is_system == false)
    |> order_by(asc: :id)
    |> Repo.all()
  end

  @doc """
  Lists all providers visible to a user:
  - Global (is_system: true)
  - Public (visibility: :public)
  - User's own private providers (visibility: :private, user_id: user_id)
  """
  @spec list_visible(integer() | nil) :: [Provider.t()]
  def list_visible(user_id \\ nil) do
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
  @spec list_public() :: [Provider.t()]
  def list_public do
    Provider
    |> where([p], p.visibility in [:global, :public])
    |> where([p], p.is_active == true)
    |> order_by(asc: :name)
    |> Repo.all()
  end

  # =============================================================================
  # Retrieval
  # =============================================================================

  @doc """
  Gets a provider by ID. Raises if not found.
  """
  @spec get!(integer()) :: Provider.t()
  def get!(id), do: Repo.get!(Provider, id)

  @doc """
  Gets a provider by ID. Returns nil if not found.
  """
  @spec get(integer()) :: Provider.t() | nil
  def get(id), do: Repo.get(Provider, id)

  @doc """
  Ensures a provider has its GIndex drives loaded.
  """
  @spec preload_drives(Provider.t()) :: Provider.t()
  def preload_drives(%Provider{} = provider), do: Repo.preload(provider, :drives)

  @doc """
  Projects a GIndex provider into the data required by the GIndex context.

  Credentials and the Ecto schema stay behind the IPTV boundary.
  """
  @spec gindex_sync_source(term()) ::
          {:ok, gindex_sync_source()} | {:error, :not_gindex_provider}
  def gindex_sync_source(%Provider{provider_type: :gindex} = provider) do
    provider = preload_drives(provider)

    source = %{
      provider_id: provider.id,
      name: provider.name,
      base_url: provider.gindex_url || provider.url,
      drives: Enum.map(provider.drives, &gindex_drive/1)
    }

    {:ok, source}
  end

  def gindex_sync_source(_provider), do: {:error, :not_gindex_provider}

  @doc """
  Persists the runtime state owned by a GIndex synchronization.

  The provider is resolved by ID so callers do not need to retain or mutate an
  IPTV schema struct.
  """
  @spec update_gindex_sync(pos_integer(), map()) ::
          :ok
          | {:error,
             :gindex_provider_not_found
             | {:invalid_gindex_sync_fields, [term()]}
             | Ecto.Changeset.t()}
  def update_gindex_sync(provider_id, attrs)
      when is_integer(provider_id) and provider_id > 0 and is_map(attrs) do
    case Map.keys(attrs) -- @gindex_sync_fields do
      [] -> update_gindex_sync_fields(provider_id, attrs)
      fields -> {:error, {:invalid_gindex_sync_fields, Enum.sort(fields)}}
    end
  end

  def update_gindex_sync(_provider_id, _attrs), do: {:error, :gindex_provider_not_found}

  defp update_gindex_sync_fields(provider_id, attrs) do
    case Repo.get_by(Provider, id: provider_id, provider_type: :gindex) do
      nil ->
        {:error, :gindex_provider_not_found}

      provider ->
        provider
        |> Provider.sync_changeset(attrs)
        |> Repo.update()
        |> case do
          {:ok, _provider} -> :ok
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  defp gindex_drive(drive) do
    %{kind: drive.drive_type, metadata: drive.metadata || %{}}
  end

  @doc """
  Gets a provider owned by a specific user.
  """
  @spec get_user_provider(integer(), integer()) :: Provider.t() | nil
  def get_user_provider(user_id, provider_id) do
    Provider
    |> where(user_id: ^user_id, id: ^provider_id)
    |> Repo.one()
  end

  @doc """
  Gets a provider by ID if it's public or global.
  Used for guest access to public content.
  """
  @spec get_public(integer()) :: Provider.t() | nil
  def get_public(provider_id) do
    Provider
    |> where(id: ^provider_id)
    |> where([p], p.visibility in [:global, :public])
    |> where([p], p.is_active == true)
    |> Repo.one()
  end

  @doc """
  Gets the global IPTV system provider (Xtream type).
  Returns the first active provider with is_system: true, visibility: :global, and provider_type: :xtream.
  For GIndex provider, use GindexProvider.get() instead.
  """
  @spec get_global() :: Provider.t() | nil
  def get_global do
    Cache.fetch_local(@global_provider_cache_key, @global_provider_cache_ttl, fn ->
      Provider
      |> where([p], p.is_system == true)
      |> where([p], p.visibility == :global)
      |> where([p], p.provider_type == :xtream)
      |> where([p], p.is_active == true)
      |> order_by([p], desc: p.inserted_at, desc: p.id)
      |> limit(1)
      |> Repo.one()
    end)
  end

  @doc """
  Gets a provider by ID if user can access it.
  User can access: global, public, or their own providers.
  """
  @spec get_playable(integer(), integer()) :: Provider.t() | nil
  def get_playable(user_id, provider_id) do
    Provider
    |> where(id: ^provider_id)
    |> where([p], p.visibility in [:global, :public] or p.user_id == ^user_id)
    |> where([p], p.is_active == true)
    |> Repo.one()
  end

  # =============================================================================
  # CRUD
  # =============================================================================

  @doc """
  Creates a new provider.
  """
  @spec create(map()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs \\ %{}) do
    %Provider{}
    |> Provider.changeset(attrs)
    |> Repo.insert()
    |> invalidate_global_cache()
  end

  @doc """
  Creates a new provider owned by the given user.
  Ownership is assigned server-side and cannot be overridden via params.
  """
  @spec create_for_user(integer(), map()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def create_for_user(user_id, attrs \\ %{}) do
    case provider_limit_state(user_id) do
      :ok ->
        %Provider{user_id: user_id}
        |> Provider.user_changeset(attrs)
        |> Repo.insert()

      {:error, :provider_limit_reached} ->
        {:error, provider_limit_changeset(user_id)}
    end
  end

  defp provider_limit_state(user_id) do
    case Billing.feature_limit_for_user_id(user_id, :max_providers) do
      nil ->
        :ok

      limit ->
        if user_provider_count(user_id) < limit do
          :ok
        else
          {:error, :provider_limit_reached}
        end
    end
  end

  defp user_provider_count(user_id) do
    from(p in Provider,
      where: p.user_id == ^user_id,
      where: p.is_system == false
    )
    |> Repo.aggregate(:count)
  end

  defp provider_limit_changeset(user_id) do
    %Provider{user_id: user_id}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:base, "provider limit reached for current plan")
  end

  @doc """
  Updates a provider.
  """
  @spec update(Provider.t(), map()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def update(%Provider{} = provider, attrs) do
    provider
    |> Provider.changeset(attrs)
    |> Repo.update()
    |> invalidate_global_cache()
  end

  @doc """
  Updates a personal provider after enforcing ownership server-side.
  """
  @spec update_for_user(integer(), Provider.t(), map()) ::
          {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def update_for_user(user_id, %Provider{} = provider, attrs) do
    if provider.user_id == user_id and provider.is_system == false do
      provider
      |> Provider.user_changeset(attrs)
      |> Repo.update()
    else
      {:error, ownership_changeset(provider)}
    end
  end

  defp ownership_changeset(provider) do
    provider
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:base, "provider does not belong to current user")
  end

  @doc """
  Deletes a provider.
  """
  @spec delete(Provider.t()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Provider{} = provider) do
    provider
    |> Repo.delete()
    |> invalidate_global_cache()
  end

  defp invalidate_global_cache({:ok, _} = result) do
    Cache.delete_local(@global_provider_cache_key)
    result
  end

  defp invalidate_global_cache(result), do: result

  @doc """
  Returns a changeset for tracking provider changes.
  """
  @spec change(Provider.t(), map()) :: Ecto.Changeset.t()
  def change(%Provider{} = provider, attrs \\ %{}) do
    Provider.changeset(provider, attrs)
  end

  # =============================================================================
  # Connection & Sync
  # =============================================================================

  @doc """
  Tests connection to a provider.
  """
  @spec test_connection(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def test_connection(url, username, password) do
    case XtreamClient.get_account_info(url, username, password) do
      {:ok, %{"user_info" => info}} -> {:ok, info}
      {:ok, info} -> {:ok, info}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Synchronously syncs a provider's content.
  """
  @spec sync(Provider.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync(provider, opts \\ []) do
    Sync.sync_all(provider, opts)
  end

  @doc """
  Asynchronously syncs a provider's content using Oban.
  Persists the job in the database, survives restarts, and controls concurrency.
  Broadcasts sync status updates via PubSub.

  ## Options

    * `:series_details` - `:skip`, `:enqueue`, or `:immediate` (default: `:skip`)

  """
  @spec async_sync(Provider.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def async_sync(provider, opts \\ [])

  def async_sync(%Provider{provider_type: :gindex} = provider, _opts) do
    # GIndex never goes through SyncProviderWorker — that path runs the
    # legacy monolithic `Gindex.Sync.sync_provider/1`, which routinely
    # exceeds Oban's 30 min timeout on catalogs with 10k+ titles. Route
    # to the dispatcher instead so the work fans out into per-root jobs
    # with the orchestrator finalizing counts at the end.
    %{"provider_id" => provider.id}
    |> SyncGindexProviderWorker.new()
    |> Oban.insert()
  end

  def async_sync(%Provider{} = provider, opts) do
    SyncProviderWorker.enqueue(provider, opts)
  end
end
