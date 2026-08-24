defmodule Streamix.Providers do
  @moduledoc """
  Application boundary for media-source provider lifecycle and availability.

  This module owns provider lookup, visibility, persistence, synchronization,
  runtime health, and the synthetic global/GIndex/torrent providers. Modules
  under `Streamix.Iptv.*` remain implementation details behind this API.
  """

  alias Streamix.Iptv.{
    Content.GindexInventory,
    GIndexProvider,
    GlobalProvider,
    Provider,
    ProviderHealth,
    ProviderHealthMonitor,
    Sync,
    TorrentProvider
  }

  alias Streamix.Iptv.Providers, as: ProviderStore

  # Lookup and visibility

  defdelegate list_providers(user_id), to: ProviderStore, as: :list
  defdelegate list_providers(user_id, opts), to: ProviderStore, as: :list
  defdelegate list_visible_providers(user_id \\ nil), to: ProviderStore, as: :list_visible
  defdelegate list_public_providers(), to: ProviderStore, as: :list_public
  defdelegate list_stale_sync_candidates(threshold), to: ProviderStore
  defdelegate get_provider!(id), to: ProviderStore, as: :get!
  defdelegate get_provider(id), to: ProviderStore, as: :get
  defdelegate preload_provider_drives(provider), to: ProviderStore, as: :preload_drives
  defdelegate get_user_provider(user_id, provider_id), to: ProviderStore
  defdelegate get_public_provider(provider_id), to: ProviderStore, as: :get_public
  defdelegate get_global_provider(), to: ProviderStore, as: :get_global
  defdelegate list_personal_xtream_providers(), to: ProviderStore, as: :list_personal_xtream
  defdelegate get_playable_provider(user_id, provider_id), to: ProviderStore, as: :get_playable

  # GIndex synchronization metadata

  @type gindex_sync_drive :: %{kind: String.t(), metadata: map()}
  @type gindex_sync_source :: %{
          provider_id: pos_integer(),
          name: String.t(),
          base_url: String.t(),
          drives: [gindex_sync_drive()]
        }

  @spec gindex_sync_source(term()) ::
          {:ok, gindex_sync_source()} | {:error, :not_gindex_provider}
  defdelegate gindex_sync_source(provider), to: ProviderStore

  @spec gindex_known_paths(pos_integer(), :movies | :series | :animes) ::
          MapSet.t(String.t())
  defdelegate gindex_known_paths(provider_id, kind), to: GindexInventory, as: :known_paths

  @spec update_gindex_sync(pos_integer(), map()) ::
          {:ok, Provider.t()}
          | {:error, :gindex_provider_not_found | {:invalid_gindex_sync_fields, term()}}
          | {:error, Ecto.Changeset.t()}
  defdelegate update_gindex_sync(provider_id, attrs), to: ProviderStore

  @spec refresh_gindex_counts(pos_integer(), map()) ::
          {:ok, Provider.t()} | {:error, :gindex_provider_not_found | Ecto.Changeset.t()}
  defdelegate refresh_gindex_counts(provider_id, attrs \\ %{}), to: ProviderStore

  # Torrent synchronization metadata

  @type torrent_sync_source :: %{
          provider_id: pos_integer(),
          name: String.t()
        }

  @spec torrent_sync_source(term()) ::
          {:ok, torrent_sync_source()} | {:error, :not_torrent_provider}
  defdelegate torrent_sync_source(provider), to: ProviderStore

  @spec update_torrent_sync(pos_integer(), map()) ::
          {:ok, Provider.t()}
          | {:error, :torrent_provider_not_found | {:invalid_torrent_sync_fields, term()}}
          | {:error, Ecto.Changeset.t()}
  defdelegate update_torrent_sync(provider_id, attrs), to: ProviderStore

  # Persistence and changesets

  defdelegate create_provider(attrs), to: ProviderStore, as: :create
  defdelegate create_provider(user_id, attrs), to: ProviderStore, as: :create_for_user
  defdelegate update_provider(provider, attrs), to: ProviderStore, as: :update

  defdelegate update_user_provider(user_id, provider, attrs),
    to: ProviderStore,
    as: :update_for_user

  defdelegate delete_provider(provider), to: ProviderStore, as: :delete
  defdelegate change_provider(provider, attrs \\ %{}), to: ProviderStore, as: :change

  def new_provider, do: %Provider{}
  def new_provider_changeset(attrs \\ %{}), do: ProviderStore.change(%Provider{}, attrs)

  # Synchronization and runtime validation

  defdelegate test_connection(url, username, password), to: ProviderStore
  defdelegate sync_provider(provider, opts \\ []), to: ProviderStore, as: :sync
  defdelegate async_sync_provider(provider), to: ProviderStore, as: :async_sync

  @type provider_sync_section :: Sync.section()

  @spec sync_provider_section(Provider.t(), provider_sync_section()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defdelegate sync_provider_section(provider, section), to: Sync, as: :sync_section

  # Synthetic providers

  defdelegate global_provider_enabled?(), to: GlobalProvider, as: :enabled?
  defdelegate ensure_global_provider(owner \\ nil), to: GlobalProvider, as: :ensure_exists!
  defdelegate gindex_provider_enabled?(), to: GIndexProvider, as: :enabled?
  defdelegate ensure_gindex_provider(), to: GIndexProvider, as: :ensure_exists!
  defdelegate torrent_provider_enabled?(), to: TorrentProvider, as: :enabled?
  defdelegate ensure_torrent_provider(), to: TorrentProvider, as: :ensure_exists!
  defdelegate get_torrent_provider(), to: TorrentProvider, as: :get
  defdelegate get_torrent_provider_ref(), to: TorrentProvider, as: :get_ref

  # Health

  defdelegate provider_health_summary(), to: ProviderHealth, as: :overall_status
  defdelegate provider_health_summary(reports), to: ProviderHealth, as: :overall_status
  defdelegate list_provider_health_reports(opts \\ []), to: ProviderHealth, as: :list_reports
  defdelegate cached_provider_health_summary(), to: ProviderHealthMonitor, as: :get
end
