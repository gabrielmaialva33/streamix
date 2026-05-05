defmodule Streamix.Iptv.Gindex.Scraper.Movies do
  @moduledoc """
  Movie scraping workflow for GIndex providers.
  """

  require Logger

  alias Streamix.Iptv.Gindex.{Client, Parser}
  alias Streamix.Iptv.Gindex.Scraper.Categories

  def scrape_movies(base_url, movies_path \\ "/1:/Filmes/") do
    Stream.resource(
      fn -> init_scrape_state(base_url, movies_path) end,
      &scrape_next_movie/1,
      fn _state -> :ok end
    )
  end

  def scrape_category(base_url, category_path) do
    rate_limit_delay()
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
    rate_limit_delay()

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

  def scrape_movie_folder(base_url, folder) do
    rate_limit_delay()
    Logger.debug("[GIndex Scraper] Scraping movie folder: #{folder.name}")

    folder_meta = Parser.parse_movie_folder(folder.name)

    case Client.list_folder(base_url, folder.path) do
      {:ok, files} ->
        files
        |> Enum.filter(fn file -> file.type == :file and Parser.video_file?(file.name) end)
        |> case do
          [] -> find_video_in_subfolders(base_url, folder.path, files)
          [video | _rest] -> build_movie_data(folder_meta, video, folder.path)
        end

      {:error, reason} ->
        Logger.warning(
          "[GIndex Scraper] Failed to list folder #{folder.path}: #{inspect(reason)}"
        )

        nil
    end
  end

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

  defp scrape_next_movie(%{done: true} = state), do: {:halt, state}

  defp scrape_next_movie(%{current_folders: [folder | rest]} = state) do
    movie = scrape_movie_folder(state.base_url, folder)
    rate_limit_delay()

    if movie do
      {[movie], %{state | current_folders: rest}}
    else
      scrape_next_movie(%{state | current_folders: rest})
    end
  end

  defp scrape_next_movie(%{categories: [category | rest_categories]} = state) do
    Logger.info("[GIndex Scraper] Processing category: #{category.name}")
    rate_limit_delay()

    case Client.list_folder_all(state.base_url, category.path) do
      {:ok, items} ->
        folders = Enum.filter(items, &(&1.type == :folder))
        Logger.info("[GIndex Scraper] Found #{length(folders)} movie folders in #{category.name}")

        scrape_next_movie(%{
          state
          | categories: rest_categories,
            current_category: category,
            current_folders: folders
        })

      {:error, _reason} ->
        scrape_next_movie(%{state | categories: rest_categories})
    end
  end

  defp scrape_next_movie(%{categories: []} = state), do: {:halt, %{state | done: true}}

  defp find_video_in_subfolders(base_url, parent_path, items) do
    items
    |> Enum.filter(&(&1.type == :folder))
    |> Enum.find_value(fn subfolder ->
      rate_limit_delay()
      check_subfolder_for_video(base_url, subfolder, parent_path)
    end)
  end

  defp check_subfolder_for_video(base_url, subfolder, parent_path) do
    case Client.list_folder(base_url, subfolder.path) do
      {:ok, files} ->
        video =
          Enum.find(files, fn file -> file.type == :file and Parser.video_file?(file.name) end)

        if video do
          folder_meta = Parser.parse_movie_folder(Path.basename(parent_path))
          build_movie_data(folder_meta, video, parent_path)
        end

      _ ->
        nil
    end
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

  defp rate_limit_delay, do: :ok
end
