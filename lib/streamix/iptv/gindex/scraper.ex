defmodule Streamix.Iptv.Gindex.Scraper do
  @moduledoc """
  Scraper for GIndex content.

  Navigates through GIndex folder structure and extracts movie/series information.

  ## GIndex Structure (GDrive):
  ```
  /1:/Filmes/
  ├── 2023/
  │   └── Nome [Original] (Ano)/
  │       └── arquivo.mkv
  ├── Filmes (5519)/
  │   └── ...
  └── Filmes 4k (227)/
      └── ...
  ```
  """

  require Logger

  alias Streamix.Iptv.Gindex.{Client, Parser}

  @delay_between_requests 500

  @doc """
  Scrapes all movies from a GIndex provider.

  Returns a stream of movie data that can be processed incrementally.
  """
  def scrape_movies(base_url, movies_path \\ "/1:/Filmes/") do
    Stream.resource(
      fn -> init_scrape_state(base_url, movies_path) end,
      &scrape_next_movie/1,
      fn _state -> :ok end
    )
  end

  @doc """
  Scrapes movies from a specific category folder.

  ## Examples

      iex> Scraper.scrape_category("https://example.workers.dev", "/1:/Filmes/2025/")
      {:ok, [%{name: "Movie Name", year: 2025, ...}]}
  """
  def scrape_category(base_url, category_path) do
    Logger.info("[GIndex Scraper] Scraping category: #{category_path}")

    with {:ok, movie_folders} <- Client.list_folder(base_url, category_path) do
      movies =
        movie_folders
        |> Enum.filter(&(&1.type == :folder))
        |> Enum.map(fn folder ->
          Process.sleep(@delay_between_requests)
          scrape_movie_folder(base_url, folder)
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, movies}
    end
  end

  @doc """
  Lists all available categories (top-level folders) in the movies section.
  """
  def list_categories(base_url, movies_path \\ "/1:/Filmes/") do
    case Client.list_folder(base_url, movies_path) do
      {:ok, items} ->
        categories =
          items
          |> Enum.filter(&(&1.type == :folder))
          |> Enum.map(fn item ->
            count = extract_category_count(item.name)

            %{
              name: clean_category_name(item.name),
              path: item.path,
              count: count
            }
          end)

        {:ok, categories}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Scrapes a single movie folder and extracts video files.
  """
  def scrape_movie_folder(base_url, folder) do
    Logger.debug("[GIndex Scraper] Scraping movie folder: #{folder.name}")

    # Parse folder name for movie metadata
    folder_meta = Parser.parse_movie_folder(folder.name)

    # List files in the folder
    case Client.list_folder(base_url, folder.path) do
      {:ok, files} ->
        video_files =
          files
          |> Enum.filter(fn file ->
            file.type == :file and Parser.video_file?(file.name)
          end)

        case video_files do
          [] ->
            # No video files, might be a nested folder structure
            # Try to find video files in subfolders
            find_video_in_subfolders(base_url, folder.path, files)

          [video | _rest] ->
            # Use the first (or best quality) video file
            build_movie_data(folder_meta, video, folder.path)
        end

      {:error, reason} ->
        Logger.warning(
          "[GIndex Scraper] Failed to list folder #{folder.path}: #{inspect(reason)}"
        )

        nil
    end
  end

  # Private functions

  defp init_scrape_state(base_url, movies_path) do
    case list_categories(base_url, movies_path) do
      {:ok, categories} ->
        %{
          base_url: base_url,
          categories: categories,
          current_category: nil,
          current_folders: [],
          done: false
        }

      {:error, _reason} ->
        %{done: true}
    end
  end

  defp scrape_next_movie(%{done: true} = state) do
    {:halt, state}
  end

  defp scrape_next_movie(%{current_folders: [folder | rest]} = state) do
    movie = scrape_movie_folder(state.base_url, folder)
    Process.sleep(@delay_between_requests)

    if movie do
      {[movie], %{state | current_folders: rest}}
    else
      scrape_next_movie(%{state | current_folders: rest})
    end
  end

  defp scrape_next_movie(%{categories: [category | rest_categories]} = state) do
    Logger.info("[GIndex Scraper] Processing category: #{category.name}")

    case Client.list_folder(state.base_url, category.path) do
      {:ok, items} ->
        folders = Enum.filter(items, &(&1.type == :folder))

        scrape_next_movie(%{
          state
          | categories: rest_categories,
            current_category: category,
            current_folders: folders
        })

      {:error, _} ->
        scrape_next_movie(%{state | categories: rest_categories})
    end
  end

  defp scrape_next_movie(%{categories: []} = state) do
    {:halt, %{state | done: true}}
  end

  defp find_video_in_subfolders(base_url, parent_path, items) do
    subfolders = Enum.filter(items, &(&1.type == :folder))

    Enum.find_value(subfolders, fn subfolder ->
      Process.sleep(@delay_between_requests)

      case Client.list_folder(base_url, subfolder.path) do
        {:ok, files} ->
          video =
            Enum.find(files, fn file ->
              file.type == :file and Parser.video_file?(file.name)
            end)

          if video do
            folder_meta = Parser.parse_movie_folder(Path.basename(parent_path))
            build_movie_data(folder_meta, video, parent_path)
          end

        _ ->
          nil
      end
    end)
  end

  defp build_movie_data(folder_meta, video_file, folder_path) do
    release_info = Parser.parse_release_name(video_file.name)
    stream_id = Parser.path_to_stream_id(video_file.path)

    %{
      stream_id: stream_id,
      name: folder_meta.name || release_info.name,
      title: folder_meta.original_name,
      year: folder_meta.year || release_info.year,
      container_extension: release_info.extension || "mkv",
      gindex_path: video_file.path,
      gindex_folder_path: folder_path,

      # Additional metadata from release name
      quality: release_info.quality,
      source: release_info.source,
      release_group: release_info.release_group,
      is_dual_audio: release_info.is_dual_audio,
      file_size: video_file.size,
      raw_filename: video_file.name
    }
  end

  defp extract_category_count(name) do
    case Regex.run(~r/\((\d+)\)$/, name) do
      [_, count] -> String.to_integer(count)
      nil -> nil
    end
  end

  defp clean_category_name(name) do
    name
    |> String.replace(~r/\s*\(\d+\)$/, "")
    |> String.trim()
  end
end
