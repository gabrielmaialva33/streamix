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
             limit: 20
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
            {:replace, [:title, :description, :end_time, :category, :icon, :lang, :updated_at]},
          conflict_target: [:epg_channel_id, :start_time]
        )

      acc + count
    end)
  end

  defp program_attrs(program, now) do
    %{
      epg_channel_id: program[:epg_channel_id],
      title: program[:title],
      description: program[:description],
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
