defmodule Streamix.Gindex.Sync.FolderBatch do
  @moduledoc false

  alias Streamix.Gindex.Sync.DiscoveryCursor

  require Logger

  @type sync_result :: {:ok, map()} | {:error, term()}

  @doc "Runs a stable, checkpointed folder scan with durable batch boundaries."
  @spec run(map(), String.t(), String.t(), keyword()) :: sync_result()
  def run(source, base_url, root_path, opts) do
    runtime = build_runtime(opts)
    checkpoint = Keyword.get(opts, :checkpoint)

    case runtime.list_fun.(base_url, root_path) do
      {:ok, folders} ->
        process_listing(source, base_url, root_path, folders, checkpoint, runtime, nil)

      {:error, {:partial_listing, %{items: folders}} = error}
      when is_list(folders) and folders != [] ->
        process_listing(
          source,
          base_url,
          root_path,
          folders,
          checkpoint,
          runtime,
          compact_listing_error(error)
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_listing(
         source,
         base_url,
         root_path,
         folders,
         checkpoint,
         runtime,
         listing_error
       ) do
    folders = folders |> Enum.filter(&folder?/1) |> Enum.sort_by(&folder_path/1)

    run_strategy(
      source,
      base_url,
      root_path,
      folders,
      checkpoint,
      runtime,
      listing_error
    )
  end

  defp build_runtime(opts) do
    %{
      batch_size: Keyword.fetch!(opts, :batch_size),
      checkpoint_fun: Keyword.get(opts, :on_checkpoint, fn _checkpoint -> :ok end),
      empty_stats: Keyword.fetch!(opts, :empty_stats),
      list_fun: Keyword.fetch!(opts, :list_fun),
      persist_fun: Keyword.fetch!(opts, :persist_fun),
      scrape_fun: Keyword.fetch!(opts, :scrape_fun),
      strategy: Keyword.get(opts, :strategy, :full_refresh),
      discovery_window: Keyword.get(opts, :discovery_window, Date.utc_today()),
      known_paths: Keyword.get(opts, :known_paths, MapSet.new()),
      process_path?: fn _path -> true end
    }
  end

  defp run_strategy(
         source,
         base_url,
         root_path,
         folders,
         checkpoint,
         %{strategy: :discovery_first} = runtime,
         listing_error
       ) do
    cursor = DiscoveryCursor.load(checkpoint, runtime.discovery_window)

    case DiscoveryCursor.phase(cursor) do
      :discover ->
        run_discovery(
          source,
          base_url,
          root_path,
          folders,
          cursor,
          runtime,
          listing_error
        )

      :refresh ->
        cursor
        |> phase_runtime(:refresh, runtime)
        |> run_phase(source, base_url, root_path, folders, DiscoveryCursor.position(cursor))
        |> apply_listing_error(listing_error)
    end
  end

  defp run_strategy(
         source,
         base_url,
         root_path,
         folders,
         checkpoint,
         runtime,
         listing_error
       ) do
    runtime
    |> run_phase(source, base_url, root_path, folders, checkpoint)
    |> apply_listing_error(listing_error)
  end

  defp run_discovery(
         source,
         base_url,
         root_path,
         folders,
         cursor,
         runtime,
         listing_error
       ) do
    result =
      cursor
      |> phase_runtime(:discover, runtime)
      |> run_phase(source, base_url, root_path, folders, DiscoveryCursor.position(cursor))
      |> apply_listing_error(listing_error)

    case result do
      {:ok, discovery_stats} ->
        continue_with_refresh(
          source,
          base_url,
          root_path,
          folders,
          cursor,
          runtime,
          listing_error,
          discovery_stats
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp continue_with_refresh(
         source,
         base_url,
         root_path,
         folders,
         cursor,
         runtime,
         listing_error,
         discovery_stats
       ) do
    {refresh_cursor, transition_checkpoint} = DiscoveryCursor.begin_refresh(cursor)

    with :ok <- persist_checkpoint(runtime.checkpoint_fun, transition_checkpoint),
         {:ok, refresh_stats} <-
           refresh_cursor
           |> phase_runtime(:refresh, runtime)
           |> run_phase(
             source,
             base_url,
             root_path,
             folders,
             DiscoveryCursor.position(refresh_cursor)
           )
           |> apply_listing_error(listing_error) do
      {:ok, merge_stats(discovery_stats, refresh_stats)}
    end
  end

  defp phase_runtime(cursor, phase, runtime) do
    checkpoint_fun = runtime.checkpoint_fun
    known_paths = runtime.known_paths

    process_path? =
      case phase do
        :discover -> &(!MapSet.member?(known_paths, &1))
        :refresh -> &MapSet.member?(known_paths, &1)
      end

    %{
      runtime
      | checkpoint_fun: fn checkpoint ->
          checkpoint_fun.(DiscoveryCursor.checkpoint(cursor, phase, checkpoint))
        end,
        process_path?: process_path?
    }
  end

  defp run_phase(runtime, source, base_url, root_path, folders, checkpoint) do
    pending = resume_after_checkpoint(folders, root_path, checkpoint)

    Logger.info(
      "[GIndex Sync] Found #{length(folders)} folders in #{root_path}; " <>
        "#{length(pending)} pending"
    )

    pending
    |> Enum.reduce_while({:ok, empty_state(runtime, checkpoint)}, fn folder, state ->
      process_folder(source, base_url, root_path, folder, state, runtime)
    end)
    |> finalize(source, root_path, runtime)
  end

  defp apply_listing_error({:ok, _stats} = success, nil), do: success
  defp apply_listing_error({:ok, _stats}, error), do: {:error, error}
  defp apply_listing_error({:error, _reason} = error, _listing_error), do: error

  defp process_folder(source, base_url, root_path, folder, {:ok, state}, runtime) do
    if runtime.process_path?.(folder_path(folder)) do
      case runtime.scrape_fun.(base_url, folder) do
        {:ok, item} ->
          continue_or_flush(source, root_path, folder, item, state, runtime)

        :empty ->
          continue_or_flush(source, root_path, folder, nil, state, runtime)

        {:error, reason} ->
          handle_folder_error(source, root_path, folder, state, reason, runtime)
      end
    else
      continue_or_flush(source, root_path, folder, nil, state, runtime)
    end
  end

  defp handle_folder_error(source, root_path, folder, state, reason, runtime) do
    if pausing_error?(reason) do
      halt_after_flush(source, root_path, state, reason, runtime)
    else
      Logger.warning(
        "[GIndex Sync] Skipping folder #{folder_path(folder)} for this cycle: " <>
          inspect(reason)
      )

      state = update_in(state, [:stats, :skipped_count], &((&1 || 0) + 1))
      continue_or_flush(source, root_path, folder, nil, state, runtime)
    end
  end

  defp pausing_error?({:quota_exhausted, _count}), do: true
  defp pausing_error?({:slice_exhausted, _count}), do: true
  defp pausing_error?({:rate_limited, _status, _retry_after}), do: true
  defp pausing_error?(_reason), do: false

  defp continue_or_flush(source, root_path, folder, item, state, runtime) do
    state = %{state | pending: state.pending ++ [{folder_path(folder), item}]}

    if length(state.pending) >= runtime.batch_size do
      case flush_pending(source, root_path, state, runtime) do
        {:ok, flushed} -> {:cont, {:ok, flushed}}
        {:error, _reason} = error -> {:halt, error}
      end
    else
      {:cont, {:ok, state}}
    end
  end

  defp halt_after_flush(source, root_path, state, reason, runtime) do
    case flush_pending(source, root_path, state, runtime) do
      {:ok, _state} -> {:halt, {:error, reason}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp finalize({:ok, state}, source, root_path, runtime) do
    case flush_pending(source, root_path, state, runtime) do
      {:ok, flushed} -> {:ok, flushed.stats}
      {:error, _reason} = error -> error
    end
  end

  defp finalize({:error, _reason} = error, _source, _root_path, _runtime), do: error

  defp empty_state(runtime, checkpoint) do
    skipped_count = checkpoint_skipped_count(checkpoint)
    stats = Map.put(runtime.empty_stats, :skipped_count, skipped_count)
    %{pending: [], stats: stats}
  end

  defp flush_pending(_source, _root_path, %{pending: []} = state, _runtime),
    do: {:ok, state}

  defp flush_pending(source, root_path, state, runtime) do
    items = state.pending |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)

    with {:ok, stats} <- persist_items(source, items, runtime),
         checkpoint =
           checkpoint_with_stats(
             root_path,
             state.pending |> List.last() |> elem(0),
             state.stats
           ),
         :ok <- persist_checkpoint(runtime.checkpoint_fun, checkpoint) do
      {:ok, %{state | pending: [], stats: merge_stats(state.stats, stats)}}
    end
  end

  defp persist_items(_source, [], runtime), do: {:ok, runtime.empty_stats}
  defp persist_items(source, items, runtime), do: runtime.persist_fun.(source, items)

  defp persist_checkpoint(checkpoint_fun, checkpoint) do
    case checkpoint_fun.(checkpoint) do
      :ok -> :ok
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, {:checkpoint_failed, reason}}
      other -> {:error, {:checkpoint_failed, other}}
    end
  end

  defp resume_after_checkpoint(folders, root_path, checkpoint) when is_map(checkpoint) do
    checkpoint_root = value(checkpoint, "root_path")
    completed_path = value(checkpoint, "folder_path")

    if checkpoint_root == root_path and is_binary(completed_path) do
      case Enum.split_while(folders, &(folder_path(&1) != completed_path)) do
        {_before, [_completed | pending]} ->
          pending

        {_before, []} ->
          Logger.warning(
            "[GIndex Sync] checkpoint folder #{completed_path} is missing from #{root_path}; " <>
              "restarting the root"
          )

          folders
      end
    else
      folders
    end
  end

  defp resume_after_checkpoint(folders, _root_path, _checkpoint), do: folders

  defp merge_stats(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_number(left_value) and is_number(right_value) do
        left_value + right_value
      else
        right_value
      end
    end)
  end

  defp value(map, "root_path"), do: Map.get(map, "root_path") || Map.get(map, :root_path)
  defp value(map, "folder_path"), do: Map.get(map, "folder_path") || Map.get(map, :folder_path)

  defp checkpoint_with_stats(root_path, folder_path, stats) do
    checkpoint = %{"root_path" => root_path, "folder_path" => folder_path}

    case Map.get(stats, :skipped_count, 0) do
      count when count > 0 -> Map.put(checkpoint, "skipped_count", count)
      _count -> checkpoint
    end
  end

  defp checkpoint_skipped_count(checkpoint) when is_map(checkpoint) do
    case Map.get(checkpoint, "skipped_count") || Map.get(checkpoint, :skipped_count) do
      count when is_integer(count) and count >= 0 -> count
      _count -> 0
    end
  end

  defp checkpoint_skipped_count(_checkpoint), do: 0

  defp folder?(%{type: type}) when type in [:folder, "folder"], do: true
  defp folder?(%{type: _type}), do: false
  defp folder?(%{path: path}) when is_binary(path), do: true
  defp folder?(_item), do: false

  defp compact_listing_error({:partial_listing, details}) do
    {:partial_listing, Map.drop(details, [:items, "items"])}
  end

  defp folder_path(folder), do: Map.fetch!(folder, :path)
end
