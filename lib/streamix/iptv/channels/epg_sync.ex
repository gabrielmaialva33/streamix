defmodule Streamix.Iptv.EpgSync do
  @moduledoc """
  Synchronization module for EPG data.
  Handles fetching and storing program guide information from Xtream Codes API.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{EpgChannel, EpgParser, EpgProgram, Provider, XtreamClient}
  alias Streamix.Repo

  require Logger

  @batch_size 500

  @doc """
  Syncs EPG data for a specific channel.
  Fetches from the Xtream Codes short EPG endpoint and upserts to database.
  """
  def sync_channel_epg(%Provider{} = provider, stream_id, epg_channel_external_id) do
    Logger.debug(
      "Syncing EPG for channel #{epg_channel_external_id} from provider #{provider.id}"
    )

    with {:ok, data} <-
           XtreamClient.get_short_epg(
             provider.url,
             provider.username,
             provider.password,
             stream_id,
             limit: 20,
             provider_id: provider.id
           ),
         {:ok, programs} <- EpgParser.parse_short_epg(data) do
      # Upsert the epg_channel first to get the integer FK
      epg_channel_id = upsert_epg_channel(provider.id, epg_channel_external_id, stream_id)

      # Add epg_channel_id (integer FK) to each program
      programs =
        Enum.map(programs, fn p ->
          Map.put(p, :epg_channel_id, epg_channel_id)
        end)

      count = upsert_programs(programs)

      Logger.debug("EPG sync completed: #{count} programs for channel #{epg_channel_external_id}")
      {:ok, count}
    else
      {:error, reason} ->
        Logger.warning(
          "EPG sync failed for channel #{epg_channel_external_id}, provider #{provider.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Syncs EPG data for multiple channels in batch.

  ## Deprecated

  Calls `sync_channel_epg/3` once per channel — N HTTP requests, where
  N is the number of channels with EPG support. The Choki provider
  treats this as a scraper burst. Use `sync_all_epg/1` instead, which
  makes a single `/xmltv.php` request like real IPTV apps do.
  """
  def sync_channels_epg(%Provider{} = provider, channels) when is_list(channels) do
    results =
      channels
      |> Enum.filter(fn ch -> ch.epg_channel_id && ch.stream_id end)
      |> Task.async_stream(
        fn channel ->
          sync_channel_epg(provider, channel.stream_id, channel.epg_channel_id)
        end,
        max_concurrency: 5,
        timeout: 30_000
      )
      |> Enum.reduce({0, 0}, fn
        {:ok, {:ok, count}}, {success, total} -> {success + 1, total + count}
        _, {success, total} -> {success, total}
      end)

    {:ok, results}
  end

  @doc """
  Syncs the **full** EPG catalog for a provider in a single HTTP
  request to `/xmltv.php` (~5-20 MB XML), then parses and upserts
  programs locally.

  This is the path real IPTV clients (XCIPTV, TiviMate, IPTVSmarters,
  IBOPlayer) use. One request to the provider, no per-channel burst,
  no WAF flag.

  Returns `{:ok, %{channels: n, programs: m}}` on success.
  """
  def sync_all_epg(%Provider{} = provider) do
    Logger.info("[EpgSync] Fetching XMLTV for provider #{provider.id}")

    with {:ok, xml} <-
           XtreamClient.get_xmltv(provider.url, provider.username, provider.password,
             provider_id: provider.id
           ),
         _ <-
           Logger.info(
             "[EpgSync] Got #{Float.round(byte_size(xml) / 1024 / 1024, 2)} MB XMLTV, parsing"
           ),
         {:ok, programs_by_channel} <- EpgParser.parse_xmltv(xml) do
      apply_xmltv_programs(provider, programs_by_channel)
    else
      {:error, reason} = err ->
        Logger.warning(
          "[EpgSync] XMLTV sync failed for provider #{provider.id}: #{inspect(reason)}"
        )

        err
    end
  end

  defp apply_xmltv_programs(provider, programs_by_channel) do
    external_ids = Map.keys(programs_by_channel)
    epg_channel_map = upsert_epg_channels(provider.id, external_ids)

    programs =
      Enum.flat_map(programs_by_channel, fn {external_id, ch_programs} ->
        attach_channel_id(ch_programs, Map.get(epg_channel_map, external_id))
      end)

    count = upsert_programs(programs)

    Logger.info(
      "[EpgSync] XMLTV sync done for provider #{provider.id}: " <>
        "#{map_size(epg_channel_map)} channels, #{count} programs"
    )

    update_epg_synced_at(provider)

    {:ok, %{channels: map_size(epg_channel_map), programs: count}}
  end

  defp attach_channel_id(_programs, nil), do: []

  defp attach_channel_id(programs, channel_id),
    do: Enum.map(programs, &Map.put(&1, :epg_channel_id, channel_id))

  # Upserts every external_id at once. Returns %{external_id => epg_channel_id}.
  # Joins with live_channels by external_id so the FK is filled in when a
  # matching channel exists; XMLTV occasionally lists channels that aren't in
  # the provider's live_streams list (e.g. removed but EPG still kept), and
  # we still want to store the EPG for them.
  defp upsert_epg_channels(provider_id, external_ids) when is_list(external_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Map external_id → live_channel_id when there is one
    live_channel_lookup =
      Streamix.Iptv.LiveChannel
      |> where(provider_id: ^provider_id)
      |> select([c], {c.epg_channel_id, c.id})
      |> Repo.all()
      |> Enum.filter(fn {ext, _} -> is_binary(ext) and ext != "" end)
      |> Map.new()

    rows =
      Enum.map(external_ids, fn ext ->
        %{
          external_id: ext,
          provider_id: provider_id,
          live_channel_id: Map.get(live_channel_lookup, ext),
          inserted_at: now,
          updated_at: now
        }
      end)

    if rows == [] do
      %{}
    else
      {_, inserted} =
        Repo.insert_all(EpgChannel, rows,
          on_conflict: {:replace, [:live_channel_id, :updated_at]},
          conflict_target: [:provider_id, :external_id],
          returning: [:id, :external_id]
        )

      Map.new(inserted, fn %{id: id, external_id: ext} -> {ext, id} end)
    end
  end

  @doc """
  Deletes EPG programs older than the specified hours.
  """
  def cleanup_old_programs(provider_id, hours_ago \\ 6) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours_ago, :hour)

    {count, _} =
      EpgProgram
      |> join(:inner, [p], ec in EpgChannel, on: p.epg_channel_id == ec.id)
      |> where([_p, ec], ec.provider_id == ^provider_id)
      |> where([p], p.end_time < ^cutoff)
      |> Repo.delete_all()

    Logger.debug("Cleaned up #{count} old EPG programs for provider #{provider_id}")
    {:ok, count}
  end

  @doc """
  Updates the provider's EPG sync timestamp.
  """
  def update_epg_synced_at(%Provider{} = provider) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    provider
    |> Provider.sync_changeset(%{epg_synced_at: now})
    |> Repo.update()
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp upsert_programs([]), do: 0

  defp upsert_programs(programs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    programs
    |> Enum.map(&program_attrs(&1, now))
    |> Enum.filter(&valid_program_attrs?/1)
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce(0, fn batch, acc ->
      {count, _} =
        Repo.insert_all(
          EpgProgram,
          batch,
          on_conflict:
            {:replace,
             [
               :title,
               :sub_title,
               :description,
               :episode_num,
               :end_time,
               :category,
               :icon,
               :lang,
               :updated_at
             ]},
          conflict_target: [:epg_channel_id, :start_time]
        )

      acc + count
    end)
  end

  defp program_attrs(program, now) do
    %{
      epg_channel_id: program[:epg_channel_id],
      title: program[:title],
      sub_title: program[:sub_title],
      description: program[:description],
      episode_num: program[:episode_num],
      start_time: program[:start_time],
      end_time: program[:end_time],
      category: program[:category],
      icon: program[:icon],
      lang: program[:lang],
      inserted_at: now,
      updated_at: now
    }
  end

  defp valid_program_attrs?(%{epg_channel_id: nil}), do: false
  defp valid_program_attrs?(%{title: nil}), do: false
  defp valid_program_attrs?(%{start_time: nil}), do: false
  defp valid_program_attrs?(%{end_time: nil}), do: false
  defp valid_program_attrs?(_), do: true

  # Upserts an epg_channel record and returns its integer ID
  defp upsert_epg_channel(provider_id, external_id, stream_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Find the live_channel by provider_id + stream_id to link
    live_channel_id =
      Streamix.Iptv.LiveChannel
      |> where(provider_id: ^provider_id, stream_id: ^stream_id)
      |> select([c], c.id)
      |> Repo.one()

    attrs = %{
      external_id: to_string(external_id),
      provider_id: provider_id,
      live_channel_id: live_channel_id,
      inserted_at: now,
      updated_at: now
    }

    {1, [%{id: id}]} =
      Repo.insert_all(EpgChannel, [attrs],
        on_conflict: {:replace, [:live_channel_id, :updated_at]},
        conflict_target: [:provider_id, :external_id],
        returning: [:id]
      )

    id
  end
end
