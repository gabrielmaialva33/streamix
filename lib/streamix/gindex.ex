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
    HealthTracker,
    MetadataProbe,
    Pacer,
    Parser,
    QuotaGuard,
    RequestBudget,
    ScanRoots,
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
  defdelegate sync_path(provider, path, kind, opts \\ []), to: Sync
  defdelegate sync_roots_for(provider, date \\ Date.utc_today()), to: SyncPlanner, as: :roots_for
  defdelegate quota_status(), to: QuotaGuard, as: :status
  defdelegate seconds_until_quota_reset(), to: QuotaGuard, as: :seconds_until_reset
  defdelegate sync_url(config), to: EndpointPolicy
  defdelegate acquire_pacing_slot(bucket), to: Pacer, as: :acquire
  defdelegate run_with_request_budget(limit, fun), to: RequestBudget, as: :run

  # Durable scan-root state. Oban executes work; it isn't the source of truth
  # for progress because completed jobs are intentionally pruned.
  defdelegate ensure_scan_cycle(provider_id, roots, opts \\ []), to: ScanRoots, as: :ensure_cycle
  defdelegate get_scan_root(provider_id, path, kind), to: ScanRoots, as: :get
  defdelegate list_scan_cycle(provider_id, cycle_id), to: ScanRoots, as: :list_cycle
  defdelegate active_scan_cycle_id(provider_id), to: ScanRoots, as: :active_cycle_id
  defdelegate latest_scan_cycle_id(provider_id), to: ScanRoots, as: :latest_cycle_id

  defdelegate reopen_failed_scan_roots(provider_id, cycle_id),
    to: ScanRoots,
    as: :reopen_failed

  defdelegate resume_retryable_scan_roots(provider_id, cycle_id),
    to: ScanRoots,
    as: :resume_retryable

  defdelegate mark_scan_root_running(root), to: ScanRoots, as: :mark_running
  defdelegate checkpoint_scan_root(root, cursor), to: ScanRoots, as: :checkpoint
  defdelegate pause_scan_root(root, reason, opts \\ []), to: ScanRoots, as: :mark_paused
  defdelegate complete_scan_root(root, stats), to: ScanRoots, as: :mark_completed
  defdelegate fail_scan_root(root, reason), to: ScanRoots, as: :mark_failed
  defdelegate scan_cycle_summary(provider_id, cycle_id), to: ScanRoots, as: :cycle_summary

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

  @doc "Credential-free upstream availability by GIndex workload."
  def upstream_status do
    config = Application.get_env(:streamix, :gindex_provider, [])

    %{
      sync: operation_status(EndpointPolicy.listing_urls(config), :list),
      playback: operation_status(EndpointPolicy.stream_urls(config, nil), :stream)
    }
  rescue
    _ ->
      %{
        sync: %{state: :unknown, errors: 0},
        playback: %{state: :unknown, errors: 0}
      }
  end

  defp operation_status(urls, operation) do
    statuses =
      urls
      |> Enum.with_index(1)
      |> Enum.map(fn {url, priority} -> {:endpoint, url, priority} end)
      |> HealthTracker.get_status()
      |> Enum.map(&get_in(&1, [:operations, operation]))

    %{
      state: if(Enum.any?(statuses, & &1.healthy), do: :available, else: :unavailable),
      errors: Enum.sum(Enum.map(statuses, & &1.errors)),
      candidates: length(statuses)
    }
  end
end
