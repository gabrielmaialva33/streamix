defmodule Streamix.Gindex do
  @moduledoc """
  Public API for GIndex integration.

  Provides functions to manage GIndex providers, sync content,
  and retrieve streaming URLs.
  """

  alias Streamix.Gindex.{
    Client,
    DisplayName,
    EndpointManager,
    EndpointPolicy,
    MetadataProbe,
    Parser,
    QuotaGuard,
    Sync,
    SyncPlanner,
    Telemetry,
    UrlCache
  }

  # Delegate sync functions
  defdelegate sync_provider(provider), to: Sync
  defdelegate sync_category(provider, category_path), to: Sync
  defdelegate list_categories(provider), to: Sync
  defdelegate list_categories(provider, movies_path), to: Sync
  defdelegate sync_kind(provider, base_url, path, kind, opts \\ []), to: Sync
  defdelegate sync_roots_for(provider, date \\ Date.utc_today()), to: SyncPlanner, as: :roots_for
  defdelegate seconds_until_quota_reset(), to: QuotaGuard, as: :seconds_until_reset
  defdelegate sync_url(config), to: EndpointPolicy

  # Delegate URL cache functions
  defdelegate get_movie_url(movie_id), to: UrlCache
  defdelegate get_episode_url(episode_id), to: UrlCache
  defdelegate invalidate_url(movie_id), to: UrlCache, as: :invalidate
  defdelegate invalidate_episode_url(episode_id), to: UrlCache, as: :invalidate_episode
  defdelegate clear_url_cache, to: UrlCache, as: :clear_all

  # Delegate parser functions
  defdelegate parse_movie_folder(folder_name), to: Parser
  defdelegate parse_release_name(filename), to: Parser
  defdelegate parse_episode_name(filename), to: Parser
  defdelegate clean_display_title(value), to: DisplayName, as: :clean_title
  defdelegate clean_episode_title(value), to: DisplayName, as: :clean_episode
  defdelegate fetch_media_tracks(type, id), to: MetadataProbe, as: :fetch

  # Direct client access for advanced usage
  defdelegate list_folder(base_url, path), to: Client
  defdelegate get_download_url(base_url, file_path), to: Client

  @doc "Operational snapshot consumed by the admin dashboard."
  def operations_status do
    %{
      quota: QuotaGuard.status(),
      telemetry: Telemetry.summary(),
      endpoints:
        EndpointManager.get_status()
        |> Enum.map(&Map.take(&1, [:name, :priority, :circuit_state, :error_count]))
    }
  rescue
    _ -> %{quota: %{count: 0, limit: 0, percent: 0}, telemetry: %{}, endpoints: []}
  end
end
