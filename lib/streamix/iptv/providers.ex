defmodule Streamix.Iptv.Providers do
  @moduledoc """
  Provider operations.

  Provides CRUD operations and retrieval of IPTV providers
  with proper access control based on visibility settings.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{Provider, Sync, XtreamClient}
  alias Streamix.Repo

  # =============================================================================
  # Listing
  # =============================================================================

  @doc """
  Lists providers owned by the user (excludes system providers).
  Use this for the provider management UI.
  """
  @spec list(integer()) :: [Provider.t()]
  def list(user_id) do
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
  Gets the global system provider.
  Returns the first active provider with is_system: true and visibility: :global.
  """
  @spec get_global() :: Provider.t() | nil
  def get_global do
    Provider
    |> where([p], p.is_system == true)
    |> where([p], p.visibility == :global)
    |> where([p], p.is_active == true)
    |> limit(1)
    |> Repo.one()
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
  end

  @doc """
  Updates a provider.
  """
  @spec update(Provider.t(), map()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def update(%Provider{} = provider, attrs) do
    provider
    |> Provider.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a provider.
  """
  @spec delete(Provider.t()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Provider{} = provider) do
    Repo.delete(provider)
  end

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
  Asynchronously syncs a provider's content.
  Broadcasts sync status updates via PubSub.
  """
  @spec async_sync(Provider.t()) :: {:ok, pid()}
  def async_sync(provider) do
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
          updated_provider = get!(provider.id)

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
