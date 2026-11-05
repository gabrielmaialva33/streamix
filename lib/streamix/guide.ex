defmodule Streamix.Guide do
  @moduledoc """
  Application boundary for EPG synchronization and TV-guide queries.

  Delivery code should use this module for current programs, guide windows,
  EPG enrichment, progress calculation, and synchronization. Specialized EPG
  modules remain implementation details behind this stable application API.
  """

  alias Streamix.Iptv.{Epg, EpgProgram, EpgSync}
  alias Streamix.Workers.SyncEpgWorker

  defdelegate get_now_and_next(provider_id, epg_channel_id), to: Epg
  defdelegate get_current_programs_batch(provider_id, epg_channel_ids), to: Epg
  defdelegate current_programs_for_channels(provider_id, channel_ids), to: Epg

  defdelegate programs_window_for_channels(provider_id, channel_ids, starts_at, ends_at),
    to: Epg

  defdelegate epg_program_progress(program), to: EpgProgram, as: :progress
  defdelegate enrich_channels_with_epg(channels, provider_id), to: Epg
  defdelegate sync_channel_epg(provider, stream_id, epg_channel_id), to: Epg, as: :sync_channel
  defdelegate sync_channels_epg(provider, channels), to: Epg, as: :sync_channels
  defdelegate ensure_epg_available(provider, channels), to: Epg
  defdelegate sync_all_epg(provider), to: EpgSync

  @doc """
  Enqueues a persistent background job to synchronize EPG for a provider.
  """
  def async_sync_epg(provider), do: SyncEpgWorker.enqueue(provider)

  @doc """
  Whether `provider`'s guide is older than its `epg_sync_interval_hours`
  (6 by default), or was never synchronized.
  """
  @spec epg_due?(map(), DateTime.t()) :: boolean()
  def epg_due?(provider, now \\ DateTime.utc_now())

  def epg_due?(%{epg_synced_at: nil}, _now), do: true

  def epg_due?(%{epg_synced_at: %DateTime{} = synced_at} = provider, now) do
    interval = Map.get(provider, :epg_sync_interval_hours) || 6
    DateTime.diff(now, synced_at, :hour) >= interval
  end
end
