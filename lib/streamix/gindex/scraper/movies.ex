defmodule Streamix.Gindex.Scraper.Movies do
  @moduledoc """
  Movie scraping workflow for GIndex providers.
  """

  require Logger

  alias Streamix.Cache
  alias Streamix.Gindex.{Client, Parser}
  alias Streamix.Gindex.Scraper.Categories

  # Top-level category listing (`/X:/Filmes/`) changes slowly — at most
  # when the operator adds a new year folder. Cache hits skip a roundtrip
  # against the 10K/day CF Worker budget, which is the binding constraint
  # for the whole sync. 12h TTL means at most two extra refreshes per
  # daily cron run if cache is cold.
  @categories_cache_ttl 12 * 60 * 60

  def scrape_movies(base_url, movies_path \\ "/1:/Filmes/") do
    Stream.resource(
      fn -> init_scrape_state(base_url, movies_path) end,
      &scrape_next_movie/1,
      fn _state -> :ok end
    )
  end

  def scrape_category(base_url, category_path) do
    Logger.info("[GIndex Scraper] Scraping category: #{category_path}")

    with {:ok, movie_folders} <- Client.list_folder_all(base_url, category_path) do
      folders = Enum.filter(movie_folders, &(&1.type == :folder))
      Logger.info("[GIndex Scraper] Found #{length(folders)} movie folders in category")

      movies =
        folders
        |> Enum.map(&scrape_movie_folder(base_url, &1))
        |> Enum.reject(&is_nil/1)

      {:ok, movies}
    end
  end

  def list_categories(base_url, movies_path \\ "/1:/Filmes/") do
    key = categories_cache_key(base_url, movies_path)

    case Cache.get(key) do
      nil ->
        with {:ok, categories} <- do_list_categories(base_url, movies_path),
             true <- categories != [] do
          Cache.set(key, categories, @categories_cache_ttl)
          {:ok, categories}
        else
          false -> {:ok, []}
          {:error, _} = err -> err
        end

      cached ->
        {:ok, cached}
    end
  end

  defp do_list_categories(base_url, movies_path) do
    case Client.list_folder_all(base_url, movies_path) do
      {:ok, items} ->
        categories =
          items
          |> Enum.filter(&(&1.type == :folder))
          |> Enum.map(&Categories.from_folder/1)

        {:ok, categories}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp categories_cache_key(base_url, path) do
    "gindex:disc:movies:" <> base_url <> ":" <> path
  end

  def scrape_movie_folder(base_url, folder) do
    case scrape_movie_folder_result(base_url, folder) do
      {:ok, movie} -> movie
      {:error, _reason} -> nil
    end
  end

  @doc false
  def scrape_movie_folder_result(base_url, folder) do
    Logger.debug("[GIndex Scraper] Scraping movie folder: #{folder.name}")

    folder_meta = Parser.parse_movie_folder(folder.name)

    case Client.list_folder_with_failover(folder.path, base_url) do
      {:ok, files} ->
        files
        |> Enum.filter(fn file -> file.type == :file and Parser.video_file?(file.name) end)
        |> case do
          [] -> find_video_in_subfolders(base_url, folder.path, files)
          [video | _rest] -> {:ok, build_movie_data(folder_meta, video, folder.path)}
        end

      {:error, reason} ->
        Logger.warning(
          "[GIndex Scraper] Failed to list folder #{folder.path}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp init_scrape_state(base_url, movies_path) do
    case list_categories(base_url, movies_path) do
      {:ok, categories} ->
        %{
          base_url: base_url,
          categories: categories,
          current_category: nil,
          current_movies: [],
          current_folders: [],
          done: false
        }

      {:error, reason} ->
        %{done: false, terminal_error: reason}
    end
  end

  defp scrape_next_movie(%{terminal_error: reason} = state) do
    {[{:gindex_error, reason}], %{state | done: true, terminal_error: nil}}
  end

  defp scrape_next_movie(%{done: true} = state), do: {:halt, state}

  defp scrape_next_movie(%{current_movies: [movie | rest]} = state) do
    {[movie], %{state | current_movies: rest}}
  end

  defp scrape_next_movie(%{current_folders: [folder | rest]} = state) do
    case scrape_movie_folder_result(state.base_url, folder) do
      {:ok, nil} ->
        scrape_next_movie(%{state | current_folders: rest})

      {:ok, movie} ->
        {[movie], %{state | current_folders: rest}}

      {:error, {:quota_exhausted, _} = reason} ->
        {[{:gindex_error, reason}], %{state | current_folders: [], categories: [], done: true}}

      {:error, {:slice_exhausted, _} = reason} ->
        {[{:gindex_error, reason}], %{state | current_folders: [], categories: [], done: true}}

      {:error, _reason} ->
        scrape_next_movie(%{state | current_folders: rest})
    end
  end

  defp scrape_next_movie(%{categories: [category | rest_categories]} = state) do
    Logger.info("[GIndex Scraper] Processing category: #{category.name}")

    case Client.list_folder_all(state.base_url, category.path) do
      {:ok, items} ->
        folders = Enum.filter(items, &(&1.type == :folder))

        movies =
          items
          |> Enum.filter(&(&1.type == :file and Parser.video_file?(&1.name)))
          |> Enum.map(&movie_from_direct_file(&1, category.path))

        Logger.info(
          "[GIndex Scraper] Found #{length(folders)} movie folders and " <>
            "#{length(movies)} direct movie files in #{category.name}"
        )

        scrape_next_movie(%{
          state
          | categories: rest_categories,
            current_category: category,
            current_movies: movies,
            current_folders: folders
        })

      {:error, {:quota_exhausted, _} = reason} ->
        {[{:gindex_error, reason}], %{state | categories: [], current_folders: [], done: true}}

      {:error, reason} ->
        {[{:gindex_error, reason}], %{state | categories: [], current_folders: [], done: true}}
    end
  end

  defp scrape_next_movie(%{categories: []} = state), do: {:halt, %{state | done: true}}

  defp find_video_in_subfolders(base_url, parent_path, items) do
    items
    |> Enum.filter(&(&1.type == :folder))
    |> Enum.reduce_while({:ok, nil}, fn subfolder, _acc ->
      case check_subfolder_for_video(base_url, subfolder, parent_path) do
        {:ok, nil} -> {:cont, {:ok, nil}}
        {:ok, movie} -> {:halt, {:ok, movie}}
        {:error, {:quota_exhausted, _}} = error -> {:halt, error}
        {:error, {:slice_exhausted, _}} = error -> {:halt, error}
        {:error, _reason} -> {:cont, {:ok, nil}}
      end
    end)
  end

  defp check_subfolder_for_video(base_url, subfolder, parent_path) do
    case Client.list_folder_with_failover(subfolder.path, base_url) do
      {:ok, files} ->
        video =
          Enum.find(files, fn file -> file.type == :file and Parser.video_file?(file.name) end)

        if video do
          folder_meta = Parser.parse_movie_folder(Path.basename(parent_path))
          {:ok, build_movie_data(folder_meta, video, parent_path)}
        else
          {:ok, nil}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def movie_from_direct_file(video_file, category_path) do
    release_info = Parser.parse_release_name(video_file.name)

    folder_meta = %{
      name: release_info.name,
      original_name: nil,
      year: release_info.year
    }

    build_movie_data(folder_meta, video_file, category_path)
  end

  defp build_movie_data(folder_meta, video_file, folder_path) do
    release_info = Parser.parse_release_name(video_file.name)

    %{
      stream_id: Parser.path_to_stream_id(video_file.path),
      name: folder_meta.name || release_info.name,
      title: folder_meta.original_name,
      year: folder_meta.year || release_info.year,
      container_extension: release_info.extension || "mkv",
      gindex_path: video_file.path,
      gindex_folder_path: folder_path,
      quality: release_info.quality,
      source: release_info.source,
      release_group: release_info.release_group,
      is_dual_audio: release_info.is_dual_audio,
      file_size: video_file.size,
      raw_filename: video_file.name
    }
  end
end
