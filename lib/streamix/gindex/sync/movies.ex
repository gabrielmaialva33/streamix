defmodule Streamix.Gindex.Sync.Movies do
  @moduledoc """
  Resumable movie synchronization for GIndex providers.

  The cursor has two levels because movie roots contain category folders and
  each category contains movie folders or direct files. A cursor only advances
  after the matching database batch and checkpoint callback both succeed.
  """

  alias Streamix.Gindex.Client
  alias Streamix.Gindex.Parser
  alias Streamix.Gindex.Scraper
  alias Streamix.Gindex.Sync.Normalizers.Movie, as: MovieNormalizer
  alias Streamix.Iptv

  require Logger

  @default_batch_size 25

  @type stats :: %{movies_count: non_neg_integer(), skipped_count: non_neg_integer()}

  @spec sync(map(), String.t(), String.t(), keyword()) ::
          {:ok, stats()} | {:error, term()}
  def sync(%{provider_id: _provider_id} = source, base_url, movies_path, opts \\ []) do
    checkpoint = Keyword.get(opts, :checkpoint)
    runtime = build_runtime(opts)

    with {:ok, categories} <- runtime.list_categories_fun.(base_url, movies_path),
         :ok <- ensure_categories(categories, movies_path) do
      categories = Enum.sort_by(categories, &item_path/1)
      pending = resume_categories(categories, movies_path, checkpoint)

      Logger.info(
        "[GIndex Sync] Found #{length(categories)} movie categories in #{movies_path}; " <>
          "#{length(pending)} pending"
      )

      sync_categories(source, base_url, movies_path, pending, checkpoint, runtime)
    end
  rescue
    error ->
      Logger.error("[GIndex Sync] Error during movie sync: #{inspect(error)}")
      {:error, error}
  end

  defp build_runtime(opts) do
    %{
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      checkpoint_fun: Keyword.get(opts, :on_checkpoint, fn _checkpoint -> :ok end),
      list_categories_fun: Keyword.get(opts, :list_categories_fun, &Scraper.list_categories/2),
      list_items_fun: Keyword.get(opts, :list_items_fun, &Client.list_folder_all/2),
      persist_fun: Keyword.get(opts, :persist_fun, &upsert_batch/2),
      scrape_folder_fun:
        Keyword.get(opts, :scrape_folder_fun, &Scraper.scrape_movie_folder_result/2)
    }
  end

  defp ensure_categories([], path) do
    Logger.warning("[GIndex Sync] No movie categories found in #{path}")
    {:error, :empty_scrape}
  end

  defp ensure_categories([_ | _], _path), do: :ok

  defp sync_categories(source, base_url, root_path, categories, checkpoint, runtime) do
    initial = %{movies_count: 0, skipped_count: checkpoint_skipped_count(checkpoint)}

    Enum.reduce_while(categories, {:ok, initial}, fn category, {:ok, totals} ->
      case sync_category_items(
             source,
             base_url,
             root_path,
             category,
             checkpoint,
             totals.skipped_count,
             runtime
           ) do
        {:ok, stats} ->
          {:cont,
           {:ok,
            %{
              movies_count: totals.movies_count + stats.movies_count,
              skipped_count: stats.skipped_count
            }}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp sync_category_items(
         source,
         base_url,
         root_path,
         category,
         checkpoint,
         skipped_count,
         runtime
       ) do
    case runtime.list_items_fun.(base_url, category.path) do
      {:ok, items} ->
        process_category_listing(
          source,
          base_url,
          root_path,
          category,
          %{items: items, complete?: true, error: nil},
          checkpoint,
          skipped_count,
          runtime
        )

      {:error, {:partial_listing, %{items: items}} = reason} when items != [] ->
        process_category_listing(
          source,
          base_url,
          root_path,
          category,
          %{items: items, complete?: false, error: reason},
          checkpoint,
          skipped_count,
          runtime
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_category_listing(
         source,
         base_url,
         root_path,
         category,
         listing,
         checkpoint,
         skipped_count,
         runtime
       ) do
    items =
      listing.items
      |> Enum.filter(&movie_item?/1)
      |> Enum.sort_by(&item_path/1)

    pending = resume_category_items(items, category.path, checkpoint, listing.complete?)

    Logger.info(
      "[GIndex Sync] Movie category #{category.path}: #{length(items)} discovered, " <>
        "#{length(pending)} pending, complete_listing=#{listing.complete?}"
    )

    result =
      pending
      |> Enum.reduce_while({:ok, empty_category_state(skipped_count)}, fn item, state ->
        process_movie_item(source, base_url, root_path, category.path, item, state, runtime)
      end)
      |> finalize_category(source, root_path, category.path, listing.complete?, runtime)

    case {result, listing.error} do
      {{:ok, stats}, nil} -> {:ok, stats}
      {{:ok, _stats}, error} -> {:error, compact_listing_error(error)}
      {{:error, _reason} = error, _listing_error} -> error
    end
  end

  defp compact_listing_error({:partial_listing, details}) when is_map(details) do
    {:partial_listing, Map.drop(details, [:items, "items"])}
  end

  defp compact_listing_error(error), do: error

  defp process_movie_item(
         source,
         base_url,
         root_path,
         category_path,
         item,
         {:ok, state},
         runtime
       ) do
    case scrape_item(base_url, category_path, item, runtime) do
      {:ok, movie} ->
        continue_or_flush(source, root_path, category_path, item, movie, state, runtime)

      {:skip, reason} ->
        Logger.warning(
          "[GIndex Sync] Skipping movie item #{item_path(item)} for this cycle: " <>
            inspect(reason)
        )

        state = %{state | skipped_count: state.skipped_count + 1}
        continue_or_flush(source, root_path, category_path, item, nil, state, runtime)

      {:error, reason} ->
        halt_after_flush(source, root_path, category_path, state, reason, runtime)
    end
  end

  defp scrape_item(_base_url, category_path, %{type: :file} = item, _runtime) do
    if Parser.video_file?(item.name) do
      {:ok, Scraper.movie_from_direct_file(item, category_path)}
    else
      {:ok, nil}
    end
  end

  defp scrape_item(base_url, _category_path, %{type: :folder} = item, runtime) do
    case runtime.scrape_folder_fun.(base_url, item) do
      {:ok, movie} -> {:ok, movie}
      {:error, {:quota_exhausted, _} = reason} -> {:error, reason}
      {:error, {:slice_exhausted, _} = reason} -> {:error, reason}
      {:error, reason} -> {:skip, reason}
    end
  end

  defp scrape_item(_base_url, _category_path, _item, _runtime), do: {:ok, nil}

  defp continue_or_flush(source, root_path, category_path, item, movie, state, runtime) do
    pending = state.pending ++ [{item_path(item), movie}]
    state = %{state | pending: pending}

    if length(pending) >= runtime.batch_size do
      case flush_pending(source, root_path, category_path, state, runtime) do
        {:ok, flushed} -> {:cont, {:ok, flushed}}
        {:error, _reason} = error -> {:halt, error}
      end
    else
      {:cont, {:ok, state}}
    end
  end

  defp halt_after_flush(source, root_path, category_path, state, reason, runtime) do
    case flush_pending(source, root_path, category_path, state, runtime) do
      {:ok, _state} -> {:halt, {:error, reason}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp finalize_category(
         {:ok, state},
         source,
         root_path,
         category_path,
         complete_listing?,
         runtime
       ) do
    with {:ok, flushed} <- flush_pending(source, root_path, category_path, state, runtime),
         :ok <-
           maybe_complete_category(
             root_path,
             category_path,
             complete_listing?,
             flushed.skipped_count,
             runtime
           ) do
      {:ok, %{movies_count: flushed.movies_count, skipped_count: flushed.skipped_count}}
    end
  end

  defp finalize_category(
         {:error, _reason} = error,
         _source,
         _root_path,
         _category_path,
         _complete_listing?,
         _runtime
       ),
       do: error

  defp flush_pending(_source, _root_path, _category_path, %{pending: []} = state, _runtime),
    do: {:ok, state}

  defp flush_pending(source, root_path, category_path, state, runtime) do
    movies = state.pending |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)

    with {:ok, inserted} <- persist_movies(source, movies, runtime.persist_fun),
         checkpoint = %{
           "root_path" => root_path,
           "category_path" => category_path,
           "item_path" => state.pending |> List.last() |> elem(0),
           "category_complete" => false,
           "skipped_count" => state.skipped_count
         },
         :ok <- persist_checkpoint(runtime.checkpoint_fun, checkpoint) do
      {:ok, %{state | pending: [], movies_count: state.movies_count + inserted}}
    end
  end

  defp persist_movies(_source, [], _persist_fun), do: {:ok, 0}
  defp persist_movies(source, movies, persist_fun), do: persist_fun.(source, movies)

  defp maybe_complete_category(_root_path, _category_path, false, _skipped_count, _runtime),
    do: :ok

  defp maybe_complete_category(root_path, category_path, true, skipped_count, runtime) do
    persist_checkpoint(runtime.checkpoint_fun, %{
      "root_path" => root_path,
      "category_path" => category_path,
      "item_path" => nil,
      "category_complete" => true,
      "skipped_count" => skipped_count
    })
  end

  defp persist_checkpoint(checkpoint_fun, checkpoint) do
    case checkpoint_fun.(checkpoint) do
      :ok -> :ok
      {:ok, _root} -> :ok
      {:error, reason} -> {:error, {:checkpoint_failed, reason}}
      other -> {:error, {:checkpoint_failed, other}}
    end
  end

  defp resume_categories(categories, root_path, checkpoint) when is_map(checkpoint) do
    checkpoint_root = value(checkpoint, "root_path")
    category_path = value(checkpoint, "category_path")
    category_complete? = value(checkpoint, "category_complete") == true

    if checkpoint_root == root_path and is_binary(category_path) do
      case Enum.split_while(categories, &(item_path(&1) != category_path)) do
        {_before, [_current | pending]} when category_complete? -> pending
        {_before, [current | pending]} -> [current | pending]
        {_before, []} -> categories
      end
    else
      categories
    end
  end

  defp resume_categories(categories, _root_path, _checkpoint), do: categories

  defp resume_category_items(items, category_path, checkpoint, complete_listing?)
       when is_map(checkpoint) do
    checkpoint_category = value(checkpoint, "category_path")
    completed_path = value(checkpoint, "item_path")
    category_complete? = value(checkpoint, "category_complete") == true

    if checkpoint_category != category_path or category_complete? or
         not is_binary(completed_path) do
      items
    else
      case Enum.split_while(items, &(item_path(&1) != completed_path)) do
        {_before, [_completed | pending]} -> pending
        {_before, []} when complete_listing? -> items
        {_before, []} -> []
      end
    end
  end

  defp resume_category_items(items, _category_path, _checkpoint, _complete_listing?), do: items

  defp movie_item?(%{type: :folder}), do: true
  defp movie_item?(%{type: :file, name: name}), do: Parser.video_file?(name)
  defp movie_item?(_item), do: false

  defp item_path(item), do: Map.fetch!(item, :path)
  defp value(map, "root_path"), do: Map.get(map, "root_path") || Map.get(map, :root_path)

  defp value(map, "category_path"),
    do: Map.get(map, "category_path") || Map.get(map, :category_path)

  defp value(map, "item_path"), do: Map.get(map, "item_path") || Map.get(map, :item_path)

  defp value(map, "category_complete") do
    case Map.fetch(map, "category_complete") do
      {:ok, value} -> value
      :error -> Map.get(map, :category_complete)
    end
  end

  defp checkpoint_skipped_count(checkpoint) when is_map(checkpoint) do
    case Map.get(checkpoint, "skipped_count") || Map.get(checkpoint, :skipped_count) do
      count when is_integer(count) and count >= 0 -> count
      _other -> 0
    end
  end

  defp checkpoint_skipped_count(_checkpoint), do: 0

  defp empty_category_state(skipped_count),
    do: %{pending: [], movies_count: 0, skipped_count: skipped_count}

  def sync_category(%{provider_id: _provider_id} = source, base_url, category_path) do
    case Scraper.scrape_category(base_url, category_path) do
      {:ok, movies} -> upsert_batch(source, movies)
      {:error, reason} -> {:error, reason}
    end
  end

  def upsert_batch(%{provider_id: provider_id}, movies) when is_list(movies) do
    movies = Enum.uniq_by(movies, & &1.stream_id)
    now = DateTime.utc_now(:second)
    entries = Enum.map(movies, &MovieNormalizer.attrs/1)

    case Iptv.upsert_gindex_movies(provider_id, entries, now) do
      {:ok, count} ->
        Logger.debug("[GIndex Sync] Upserted #{count} movies")
        {:ok, count}

      {:error, reason} ->
        Logger.error("[GIndex Sync] Failed to upsert movies: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    error ->
      Logger.error("[GIndex Sync] Failed to upsert movies: #{inspect(error)}")
      {:error, error}
  end
end
