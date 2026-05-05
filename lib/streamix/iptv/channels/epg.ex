defmodule Streamix.Iptv.Epg do
  @moduledoc """
  Context module for EPG operations.
  Provides query functions for retrieving program data with caching.
  """

  import Ecto.Query, warn: false

  alias Streamix.{Cache, Repo}
  alias Streamix.Iptv.{EpgChannel, EpgProgram, EpgSync, LiveChannel, Provider}

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

  defp fetch_now_and_next(provider_id, epg_channel_external_id) do
    now = DateTime.utc_now()

    # Resolve external_id to epg_channel integer id
    # Single query: get up to 2 programs that haven't ended yet, ordered by start_time
    programs =
      EpgProgram
      |> join(:inner, [p], ec in EpgChannel, on: p.epg_channel_id == ec.id)
      |> where([_p, ec], ec.provider_id == ^provider_id)
      |> where([_p, ec], ec.external_id == ^epg_channel_external_id)
      |> where([p], p.end_time > ^now)
      |> order_by([p], asc: p.start_time)
      |> limit(2)
      |> select([p], p)
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

  Granular per-id cache (`Cache.epg_current_key/2`, TTL = #{@epg_now_ttl}s) — DB
  is hit only for cache misses, so reused channels across screens/scrolls
  resolve in O(1). Returns a map of `external_id => program | nil`.
  """
  def get_current_programs_batch(provider_id, epg_channel_external_ids)
      when is_list(epg_channel_external_ids) do
    external_ids = Enum.uniq(Enum.filter(epg_channel_external_ids, & &1))

    if Enum.empty?(external_ids) do
      %{}
    else
      {hits, misses} = lookup_cached_programs(provider_id, external_ids)

      fresh =
        if Enum.empty?(misses), do: %{}, else: fetch_current_programs(provider_id, misses)

      cache_current_programs(provider_id, misses, fresh)

      Map.merge(hits, fresh)
    end
  end

  defp lookup_cached_programs(provider_id, external_ids) do
    Enum.reduce(external_ids, {%{}, []}, fn id, {hits, misses} ->
      case Cache.get(Cache.epg_current_key(provider_id, id)) do
        nil -> {hits, [id | misses]}
        :__epg_current_miss__ -> {Map.put(hits, id, nil), misses}
        program -> {Map.put(hits, id, program), misses}
      end
    end)
  end

  defp fetch_current_programs(provider_id, external_ids) do
    now = DateTime.utc_now()

    EpgProgram
    |> join(:inner, [p], ec in EpgChannel, on: p.epg_channel_id == ec.id)
    |> where([_p, ec], ec.provider_id == ^provider_id)
    |> where([_p, ec], ec.external_id in ^external_ids)
    |> where([p], p.start_time <= ^now and p.end_time > ^now)
    |> select([p, ec], {ec.external_id, p})
    |> Repo.all()
    |> Map.new()
  end

  defp cache_current_programs(provider_id, external_ids, fresh) do
    Enum.each(external_ids, fn id ->
      key = Cache.epg_current_key(provider_id, id)
      # Negative caching keeps cold channels off the DB while still returning nil.
      value = Map.get(fresh, id) || :__epg_current_miss__
      Cache.set(key, value, @epg_now_ttl)
    end)
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

  @doc """
  Returns programs for LiveChannel IDs within a time window.

  Results are keyed by the requested `LiveChannel.id` values as strings so API
  callers can safely preserve their channel-card IDs. Missing channels are
  included with an empty list.
  """
  def programs_window_for_channels(provider_id, channel_ids, starts_at, ends_at)
      when is_list(channel_ids) do
    provider_id
    |> channel_programs_query(channel_ids)
    |> where(
      [program: program],
      program.end_time > ^starts_at and program.start_time < ^ends_at
    )
    |> order_by([channel: channel, program: program], asc: channel.id, asc: program.start_time)
    |> select([channel: channel, program: program], {channel.id, program})
    |> Repo.all()
    |> group_program_rows(channel_ids, [])
  end

  @doc """
  Returns the currently airing program for each requested LiveChannel ID.

  Results are keyed by the requested `LiveChannel.id` values as strings. Missing
  channels or channels without a current EPG row are included with `nil`.
  """
  def current_programs_for_channels(provider_id, channel_ids, now \\ DateTime.utc_now())
      when is_list(channel_ids) do
    provider_id
    |> channel_programs_query(channel_ids)
    |> where([program: program], program.start_time <= ^now and program.end_time > ^now)
    |> select([channel: channel, program: program], {channel.id, program})
    |> Repo.all()
    |> group_program_rows(channel_ids, nil)
  end

  defp channel_programs_query(provider_id, channel_ids) do
    from(channel in LiveChannel,
      as: :channel,
      where: channel.id in ^channel_ids,
      where: channel.provider_id == ^provider_id,
      where: not is_nil(channel.epg_channel_id),
      join: epg_channel in EpgChannel,
      as: :epg_channel,
      on:
        epg_channel.provider_id == channel.provider_id and
          epg_channel.external_id == channel.epg_channel_id,
      join: program in EpgProgram,
      as: :program,
      on: program.epg_channel_id == epg_channel.id
    )
  end

  defp group_program_rows(rows, channel_ids, default) do
    grouped = group_program_rows(rows, default)

    Enum.reduce(channel_ids, grouped, fn channel_id, acc ->
      Map.put_new(acc, to_string(channel_id), default)
    end)
  end

  defp group_program_rows(rows, []) do
    rows
    |> Enum.group_by(fn {channel_id, _program} -> to_string(channel_id) end, fn {_id, program} ->
      program
    end)
  end

  defp group_program_rows(rows, nil) do
    Map.new(rows, fn {channel_id, program} -> {to_string(channel_id), program} end)
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
      with {:ok, _results} <- sync_channels(provider, channels),
           {:ok, _provider} <- EpgSync.update_epg_synced_at(provider) do
        :ok
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
