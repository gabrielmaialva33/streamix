defmodule Streamix.Gindex.Sync.Series do
  @moduledoc """
  Series synchronization for GIndex providers.
  """

  alias Streamix.Gindex.Scraper
  alias Streamix.Gindex.Sync.Persistence

  require Logger

  @default_batch_size 5

  def sync(%{provider_id: _provider_id} = source, base_url, series_paths, opts \\ []) do
    Logger.info("[GIndex Sync] Starting series sync from #{length(series_paths)} paths")

    checkpoint = Keyword.get(opts, :checkpoint)
    runtime = build_runtime(opts)

    Enum.reduce_while(series_paths, {:ok, %{series_count: 0, episodes_count: 0}}, fn path,
                                                                                     {:ok, acc} ->
      case sync_path(source, base_url, path, checkpoint, runtime) do
        {:ok, stats} ->
          {:cont,
           {:ok,
            %{
              series_count: acc.series_count + stats.series_count,
              episodes_count: acc.episodes_count + stats.episodes_count
            }}}

        {:error, reason} ->
          Logger.warning("[GIndex Sync] Failed to scrape series: #{inspect(reason)}")
          {:halt, {:error, reason}}
      end
    end)
  rescue
    e ->
      Logger.error("[GIndex Sync] Error during series sync: #{inspect(e)}")
      {:error, e}
  end

  def upsert_batch(%{provider_id: _provider_id} = source, series_list)
      when is_list(series_list) do
    now = DateTime.utc_now(:second)

    Enum.reduce_while(series_list, {:ok, %{series_count: 0, episodes_count: 0}}, fn
      series_data, {:ok, acc} ->
        case Persistence.upsert_series_content(source, series_data, now) do
          {:ok, episode_count} ->
            {:cont,
             {:ok,
              %{
                series_count: acc.series_count + 1,
                episodes_count: acc.episodes_count + episode_count
              }}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end)
  rescue
    e ->
      Logger.error("[GIndex Sync] Failed to upsert series batch: #{inspect(e)}")
      {:error, e}
  end

  defp build_runtime(opts) do
    %{
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      checkpoint_fun: Keyword.get(opts, :on_checkpoint, fn _checkpoint -> :ok end),
      list_fun: Keyword.get(opts, :list_fun, &Scraper.list_series_folders/2),
      persist_fun: Keyword.get(opts, :persist_fun, &upsert_batch/2),
      scrape_fun: Keyword.get(opts, :scrape_fun, &Scraper.scrape_single_series_result/2)
    }
  end

  defp sync_path(source, base_url, path, checkpoint, runtime) do
    with {:ok, folders} <- runtime.list_fun.(base_url, path) do
      # GIndex doesn't promise listing order. A stable path sort keeps the
      # cursor deterministic across quota windows even when an endpoint
      # returns the same folders in a different order.
      folders = Enum.sort_by(folders, &folder_path/1)
      pending_folders = resume_after_checkpoint(folders, path, checkpoint)

      Logger.info(
        "[GIndex Sync] Found #{length(folders)} series folders in #{path}; " <>
          "#{length(pending_folders)} pending"
      )

      sync_folders(source, base_url, path, pending_folders, runtime)
    end
  end

  defp sync_folders(source, base_url, path, folders, runtime) do
    folders
    |> Enum.reduce_while({:ok, empty_state()}, fn folder, state ->
      process_folder(source, base_url, path, folder, state, runtime)
    end)
    |> finalize_path(source, path, runtime)
  end

  defp process_folder(source, base_url, path, folder, {:ok, state}, runtime) do
    case runtime.scrape_fun.(base_url, folder) do
      {:ok, series} ->
        continue_or_flush(source, path, folder, series, state, runtime)

      :empty ->
        continue_or_flush(source, path, folder, nil, state, runtime)

      {:error, reason} ->
        halt_after_flush(source, path, state, reason, runtime)
    end
  end

  defp halt_after_flush(source, path, state, reason, runtime) do
    case flush_pending(source, path, state, runtime) do
      {:ok, _state} -> {:halt, {:error, reason}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp finalize_path({:ok, state}, source, path, runtime) do
    case flush_pending(source, path, state, runtime) do
      {:ok, flushed} ->
        {:ok,
         %{
           series_count: flushed.series_count,
           episodes_count: flushed.episodes_count
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp finalize_path({:error, _reason} = error, _source, _path, _runtime), do: error

  defp empty_state do
    %{pending: [], series_count: 0, episodes_count: 0}
  end

  defp continue_or_flush(source, path, folder, series, state, runtime) do
    state = %{state | pending: state.pending ++ [{folder_path(folder), series}]}

    if length(state.pending) >= runtime.batch_size do
      case flush_pending(source, path, state, runtime) do
        {:ok, flushed} -> {:cont, {:ok, flushed}}
        {:error, _reason} = error -> {:halt, error}
      end
    else
      {:cont, {:ok, state}}
    end
  end

  defp flush_pending(_source, _path, %{pending: []} = state, _runtime),
    do: {:ok, state}

  defp flush_pending(source, path, state, runtime) do
    series_list =
      state.pending
      |> Enum.map(&elem(&1, 1))
      |> Enum.reject(&is_nil/1)

    with {:ok, stats} <- persist_series(source, series_list, runtime.persist_fun),
         checkpoint = %{
           "root_path" => path,
           "folder_path" => state.pending |> List.last() |> elem(0)
         },
         :ok <- persist_checkpoint(runtime.checkpoint_fun, checkpoint) do
      {:ok,
       %{
         state
         | pending: [],
           series_count: state.series_count + stats.series_count,
           episodes_count: state.episodes_count + stats.episodes_count
       }}
    end
  end

  defp persist_series(_source, [], _persist_fun),
    do: {:ok, %{series_count: 0, episodes_count: 0}}

  defp persist_series(source, series_list, persist_fun) do
    persist_fun.(source, series_list)
  end

  defp persist_checkpoint(checkpoint_fun, checkpoint) do
    case checkpoint_fun.(checkpoint) do
      :ok -> :ok
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, {:checkpoint_failed, reason}}
      other -> {:error, {:checkpoint_failed, other}}
    end
  end

  defp resume_after_checkpoint(folders, path, checkpoint) when is_map(checkpoint) do
    root_path = Map.get(checkpoint, "root_path") || Map.get(checkpoint, :root_path)
    completed_path = Map.get(checkpoint, "folder_path") || Map.get(checkpoint, :folder_path)

    if root_path == path and is_binary(completed_path) do
      case Enum.split_while(folders, &(folder_path(&1) != completed_path)) do
        {_before, [_completed | pending]} ->
          pending

        {_before, []} ->
          Logger.warning(
            "[GIndex Sync] checkpoint folder #{completed_path} is missing from #{path}; " <>
              "restarting the root"
          )

          folders
      end
    else
      folders
    end
  end

  defp resume_after_checkpoint(folders, _path, _checkpoint), do: folders

  defp folder_path(folder), do: Map.fetch!(folder, :path)
end
