defmodule Streamix.Iptv.Epg do
  @moduledoc """
  Context module for EPG operations.
  Provides query functions for retrieving program data with caching.
  """

  import Ecto.Query, warn: false

  alias Streamix.{Cache, Repo}
  alias Streamix.Iptv.{EpgProgram, EpgSync, Provider}

  @epg_now_ttl 60

  # =============================================================================
  # Query Functions
  # =============================================================================

  @doc """
  Gets the current and next program for a channel.
  Uses caching to reduce database load.
  """
  def get_now_and_next(provider_id, epg_channel_id) when is_binary(epg_channel_id) do
    cache_key = Cache.epg_now_key(provider_id, epg_channel_id)

    Cache.fetch(cache_key, @epg_now_ttl, fn ->
      fetch_now_and_next(provider_id, epg_channel_id)
    end)
  end

  def get_now_and_next(_provider_id, nil), do: %{current: nil, next: nil}
  def get_now_and_next(_provider_id, _), do: %{current: nil, next: nil}

  defp fetch_now_and_next(provider_id, epg_channel_id) do
    now = DateTime.utc_now()

    # Single query: get up to 2 programs that haven't ended yet, ordered by start_time
    # This covers both current (start_time <= now < end_time) and next (start_time > now)
    programs =
      EpgProgram
      |> where([p], p.provider_id == ^provider_id)
      |> where([p], p.epg_channel_id == ^epg_channel_id)
      |> where([p], p.end_time > ^now)
      |> order_by([p], asc: p.start_time)
      |> limit(2)
      |> Repo.all()

    # Separate into current and next based on start_time
    {current, next} =
      case programs do
        [] ->
          {nil, nil}

        [first] ->
          if DateTime.compare(first.start_time, now) in [:lt, :eq] do
            {first, nil}
          else
            {nil, first}
          end

        [first, second] ->
          if DateTime.compare(first.start_time, now) in [:lt, :eq] do
            {first, second}
          else
            # Both are future programs, first is next
            {nil, first}
          end
      end

    %{current: current, next: next}
  end

  @doc """
  Gets the current program for multiple channels at once.
  Efficient batch query for channel listings.
  Returns a map of epg_channel_id => program.
  """
  def get_current_programs_batch(provider_id, epg_channel_ids) when is_list(epg_channel_ids) do
    # Filter out nil values
    epg_channel_ids = Enum.filter(epg_channel_ids, & &1)

    if Enum.empty?(epg_channel_ids) do
      %{}
    else
      now = DateTime.utc_now()

      EpgProgram
      |> where([p], p.provider_id == ^provider_id)
      |> where([p], p.epg_channel_id in ^epg_channel_ids)
      |> where([p], p.start_time <= ^now and p.end_time > ^now)
      |> Repo.all()
      |> Map.new(fn p -> {p.epg_channel_id, p} end)
    end
  end

  @doc """
  Enriches a list of channels with current EPG data.
  Adds :current_program field to each channel.
  """
  def enrich_channels_with_epg(channels, provider_id) when is_list(channels) do
    epg_channel_ids = Enum.map(channels, & &1.epg_channel_id)
    current_programs = get_current_programs_batch(provider_id, epg_channel_ids)

    Enum.map(channels, fn channel ->
      epg = Map.get(current_programs, channel.epg_channel_id)
      Map.put(channel, :current_program, epg)
    end)
  end

  # =============================================================================
  # Sync Delegation
  # =============================================================================

  @doc """
  Syncs EPG data for a specific channel.
  Delegates to EpgSync.sync_channel_epg/3.
  """
  def sync_channel(provider, stream_id, epg_channel_id) do
    EpgSync.sync_channel_epg(provider, stream_id, epg_channel_id)
  end

  @doc """
  Syncs EPG data for multiple channels.
  Delegates to EpgSync.sync_channels_epg/2.
  """
  def sync_channels(provider, channels) do
    EpgSync.sync_channels_epg(provider, channels)
  end

  @doc """
  Cleans up old EPG programs.
  """
  def cleanup(provider_id, hours_ago \\ 6) do
    EpgSync.cleanup_old_programs(provider_id, hours_ago)
  end

  # =============================================================================
  # Batch EPG Sync (for on-demand loading)
  # =============================================================================

  @doc """
  Ensures EPG data is available for a provider.
  Checks if EPG was synced recently, if not syncs for all channels.
  Returns :ok or {:error, reason}.
  """
  def ensure_epg_available(%Provider{} = provider, channels) when is_list(channels) do
    # Check if we need to sync (EPG older than sync interval or never synced)
    needs_sync? = epg_needs_sync?(provider)

    if needs_sync? do
      # Sync EPG for channels that have epg_channel_id
      case sync_channels(provider, channels) do
        {:ok, _results} ->
          # Update the sync timestamp
          EpgSync.update_epg_synced_at(provider)
          :ok

        error ->
          error
      end
    else
      :ok
    end
  end

  defp epg_needs_sync?(%Provider{epg_synced_at: nil}), do: true

  defp epg_needs_sync?(%Provider{
         epg_synced_at: synced_at,
         epg_sync_interval_hours: interval
       }) do
    interval = interval || 6
    hours_since_sync = DateTime.diff(DateTime.utc_now(), synced_at, :hour)
    hours_since_sync >= interval
  end
end
