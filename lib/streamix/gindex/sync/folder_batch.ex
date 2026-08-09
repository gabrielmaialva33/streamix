defmodule Streamix.Gindex.Sync.FolderBatch do
  @moduledoc false

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
    pending = resume_after_checkpoint(folders, root_path, checkpoint)

    Logger.info(
      "[GIndex Sync] Found #{length(folders)} folders in #{root_path}; " <>
        "#{length(pending)} pending complete_listing=#{is_nil(listing_error)}"
    )

    result =
      pending
      |> Enum.reduce_while({:ok, empty_state(runtime)}, fn folder, state ->
        process_folder(source, base_url, root_path, folder, state, runtime)
      end)
      |> finalize(source, root_path, runtime)

    case {result, listing_error} do
      {{:ok, _stats} = success, nil} -> success
      {{:ok, _stats}, error} -> {:error, error}
      {{:error, _reason} = error, _listing_error} -> error
    end
  end

  defp build_runtime(opts) do
    %{
      batch_size: Keyword.fetch!(opts, :batch_size),
      checkpoint_fun: Keyword.get(opts, :on_checkpoint, fn _checkpoint -> :ok end),
      empty_stats: Keyword.fetch!(opts, :empty_stats),
      list_fun: Keyword.fetch!(opts, :list_fun),
      persist_fun: Keyword.fetch!(opts, :persist_fun),
      scrape_fun: Keyword.fetch!(opts, :scrape_fun)
    }
  end

  defp process_folder(source, base_url, root_path, folder, {:ok, state}, runtime) do
    case runtime.scrape_fun.(base_url, folder) do
      {:ok, item} -> continue_or_flush(source, root_path, folder, item, state, runtime)
      :empty -> continue_or_flush(source, root_path, folder, nil, state, runtime)
      {:error, reason} -> halt_after_flush(source, root_path, state, reason, runtime)
    end
  end

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

  defp empty_state(runtime), do: %{pending: [], stats: runtime.empty_stats}

  defp flush_pending(_source, _root_path, %{pending: []} = state, _runtime),
    do: {:ok, state}

  defp flush_pending(source, root_path, state, runtime) do
    items = state.pending |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)

    with {:ok, stats} <- persist_items(source, items, runtime),
         checkpoint = %{
           "root_path" => root_path,
           "folder_path" => state.pending |> List.last() |> elem(0)
         },
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

  defp folder?(%{type: type}) when type in [:folder, "folder"], do: true
  defp folder?(%{type: _type}), do: false
  defp folder?(%{path: path}) when is_binary(path), do: true
  defp folder?(_item), do: false

  defp compact_listing_error({:partial_listing, details}) do
    {:partial_listing, Map.drop(details, [:items, "items"])}
  end

  defp folder_path(folder), do: Map.fetch!(folder, :path)
end
