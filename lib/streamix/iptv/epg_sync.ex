defmodule Streamix.Iptv.EpgSync do
  @moduledoc """
  Synchronization module for EPG data.
  Handles fetching and storing program guide information from Xtream Codes API.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{EpgParser, EpgProgram, Provider, XtreamClient}
  alias Streamix.Repo

  require Logger

  @batch_size 500

  @doc """
  Syncs EPG data for a specific channel.
  Fetches from the Xtream Codes short EPG endpoint and upserts to database.
  """
  def sync_channel_epg(%Provider{} = provider, stream_id, epg_channel_id) do
    Logger.debug("Syncing EPG for channel #{epg_channel_id} from provider #{provider.id}")

    with {:ok, data} <-
           XtreamClient.get_short_epg(
             provider.url,
             provider.username,
             provider.password,
             stream_id,
             limit: 20
           ),
         {:ok, programs} <- EpgParser.parse_short_epg(data) do
      # Add provider_id and ensure epg_channel_id is set
      programs =
        Enum.map(programs, fn p ->
          Map.merge(p, %{
            provider_id: provider.id,
            epg_channel_id: epg_channel_id
          })
        end)

      count = upsert_programs(programs, provider.id)

      Logger.debug("EPG sync completed: #{count} programs for channel #{epg_channel_id}")
      {:ok, count}
    else
      {:error, reason} ->
        Logger.warning(
          "EPG sync failed for channel #{epg_channel_id}, provider #{provider.id}: #{inspect(reason)}"
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
      |> where([p], p.provider_id == ^provider_id)
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

  defp upsert_programs([], _provider_id), do: 0

  defp upsert_programs(programs, _provider_id) do
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
          conflict_target: [:provider_id, :epg_channel_id, :start_time]
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
      provider_id: program[:provider_id],
      inserted_at: now,
      updated_at: now
    }
  end

  defp valid_program_attrs?(%{epg_channel_id: nil}), do: false
  defp valid_program_attrs?(%{title: nil}), do: false
  defp valid_program_attrs?(%{start_time: nil}), do: false
  defp valid_program_attrs?(%{end_time: nil}), do: false
  defp valid_program_attrs?(%{provider_id: nil}), do: false
  defp valid_program_attrs?(_), do: true
end
