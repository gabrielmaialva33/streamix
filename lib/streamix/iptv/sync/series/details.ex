defmodule Streamix.Iptv.Sync.Series.Details do
  @moduledoc """
  Series details synchronization orchestration and chunk processing.
  """

  import Ecto.Query, warn: false

  alias Streamix.Iptv.{Provider, Providers, Series, XtreamClient}
  alias Streamix.Iptv.Sync.Series.SeasonsEpisodes
  alias Streamix.Iptv.Sync.Telemetry
  alias Streamix.Repo

  require Logger

  @chunk_size 100

  @doc """
  Syncs seasons and episodes for all series of a provider.
  """
  def sync_all_series_details(%Provider{} = provider) do
    Logger.info("Syncing all series details for provider #{provider.id}")

    total = Repo.aggregate(from(s in Series, where: s.provider_id == ^provider.id), :count)

    Logger.info("Syncing details for #{total} series (this may take a while)...")
    Telemetry.progress(provider, :details, current: 0, total: total, type: :series)

    query = from(s in Series, where: s.provider_id == ^provider.id, order_by: s.id)

    results =
      Repo.transaction(
        fn ->
          query
          |> Repo.stream(max_rows: @chunk_size)
          |> Stream.chunk_every(@chunk_size)
          |> Enum.reduce(empty_results(), fn chunk, acc ->
            chunk_results = process_series_chunk(chunk)
            merged = merge_results(acc, chunk_results)

            Telemetry.progress(provider, :details,
              current: merged.success + merged.failed,
              total: total,
              type: :series
            )

            merged
          end)
        end,
        timeout: :infinity
      )

    case results do
      {:ok, final_results} ->
        Logger.info(
          "Series details sync completed: #{final_results.success}/#{total} series, " <>
            "#{final_results.seasons} seasons, #{final_results.episodes} episodes"
        )

        {:ok, final_results}

      {:error, reason} ->
        Logger.error("Series details sync failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Syncs seasons and episodes for a specific series.
  """
  def sync_series_details(%Series{} = series) do
    provider = Providers.get!(series.provider_id)

    case XtreamClient.get_series_info(
           provider.url,
           provider.username,
           provider.password,
           series.series_id
         ) do
      {:ok, info} ->
        SeasonsEpisodes.sync(series, info)

      {:error, reason} ->
        {:error, {:series_info_failed, reason}}
    end
  end

  defp process_series_chunk(series_list) do
    series_list
    |> Task.async_stream(
      fn series ->
        case sync_series_details(series) do
          {:ok, result} -> {:ok, series.id, result}
          {:error, reason} -> {:error, series.id, reason}
        end
      end,
      max_concurrency: 10,
      timeout: 60_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(empty_results(), fn
      {:ok, {:ok, _id, %{seasons: seasons, episodes: episodes}}}, acc ->
        %{
          acc
          | success: acc.success + 1,
            seasons: acc.seasons + seasons,
            episodes: acc.episodes + episodes
        }

      {:ok, {:error, _id, _reason}}, acc ->
        %{acc | failed: acc.failed + 1}

      {:exit, _reason}, acc ->
        %{acc | failed: acc.failed + 1}
    end)
  end

  defp merge_results(acc, chunk_results) do
    %{
      success: acc.success + chunk_results.success,
      failed: acc.failed + chunk_results.failed,
      episodes: acc.episodes + chunk_results.episodes,
      seasons: acc.seasons + chunk_results.seasons
    }
  end

  defp empty_results do
    %{success: 0, failed: 0, episodes: 0, seasons: 0}
  end
end
