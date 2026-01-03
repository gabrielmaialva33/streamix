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

  # Base delay between requests to respect Cloudflare Workers rate limits
  # Free plan: 1,000 req/min but GIndex makes internal subrequests to Google Drive
  # 10000ms = ~6 req/min = ultra conservative to avoid 500 errors
  @base_delay 10000
  # Max jitter to add (0-5000ms random) to smooth out request pattern
  @max_jitter 5000

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
    # Delay before listing category
    rate_limit_delay()
    Logger.info("[GIndex Scraper] Scraping category: #{category_path}")

    # Use list_folder_all to handle pagination
    with {:ok, movie_folders} <- Client.list_folder_all(base_url, category_path) do
      folders = Enum.filter(movie_folders, &(&1.type == :folder))
      Logger.info("[GIndex Scraper] Found #{length(folders)} movie folders in category")

      movies =
        folders
        |> Enum.map(fn folder ->
          # scrape_movie_folder already has delay
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
    # Delay before listing categories
    rate_limit_delay()
    # Top-level categories usually don't need pagination, but use it anyway
    case Client.list_folder_all(base_url, movies_path) do
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

  # =============================================================================
  # Anime Scraping Functions
  # =============================================================================

  @doc """
  Scrapes all animes from a GIndex provider.

  Returns a list of anime data with releases and episodes.
  """
  def scrape_animes(base_url, anime_path \\ "/0:/Animes/") do
    # Delay before listing animes
    rate_limit_delay()
    Logger.info("[GIndex Scraper] Scraping animes from: #{anime_path}")

    case Client.list_folder_all(base_url, anime_path) do
      {:ok, items} ->
        folders = Enum.filter(items, &(&1.type == :folder))
        Logger.info("[GIndex Scraper] Found #{length(folders)} anime folders")

        animes =
          folders
          |> Enum.map(fn folder ->
            # scrape_single_anime already has delay
            scrape_single_anime(base_url, folder)
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, animes}

      {:error, reason} ->
        Logger.warning(
          "[GIndex Scraper] Failed to list anime folder #{anime_path}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Scrapes a single anime folder and extracts releases and episodes.
  """
  def scrape_single_anime(base_url, folder) do
    # Delay before request
    rate_limit_delay()
    Logger.debug("[GIndex Scraper] Scraping anime: #{folder.name}")

    # Parse anime folder name
    folder_meta = Parser.parse_anime_folder(folder.name)
    anime_id = Parser.path_to_stream_id(folder.path)

    # List contents (release folders)
    case Client.list_folder(base_url, folder.path) do
      {:ok, items} ->
        # Find release folders (subfolders with video files)
        release_folders = Enum.filter(items, &(&1.type == :folder))

        # Scrape releases
        releases = scrape_anime_releases(base_url, release_folders)

        if Enum.empty?(releases) do
          nil
        else
          total_episodes = Enum.sum(Enum.map(releases, & &1.episode_count))

          %{
            series_id: anime_id,
            name: folder_meta.name,
            title: folder_meta.original_name,
            year: folder_meta.year,
            gindex_path: folder.path,
            seasons: releases,
            season_count: length(releases),
            episode_count: total_episodes,
            content_type: "anime"
          }
        end

      {:error, reason} ->
        Logger.warning("[GIndex Scraper] Failed to list anime #{folder.name}: #{inspect(reason)}")
        nil
    end
  end

  @doc """
  Scrapes releases from a list of release folders.

  Each release is treated as a "season" for data model compatibility.
  """
  def scrape_anime_releases(base_url, release_folders) do
    release_folders
    |> Enum.with_index(1)
    |> Enum.map(fn {folder, index} ->
      # scrape_single_anime_release already has delay
      scrape_single_anime_release(base_url, folder, index)
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.release_score, :desc)
  end

  @doc """
  Scrapes a single release folder for episodes.
  """
  def scrape_single_anime_release(base_url, folder, release_index) do
    # Delay before request
    rate_limit_delay()
    Logger.debug("[GIndex Scraper] Scraping anime release: #{folder.name}")

    # Parse release info
    release_meta = Parser.parse_release_folder(folder.name)

    case Client.list_folder(base_url, folder.path) do
      {:ok, items} ->
        # Find video files
        video_files =
          items
          |> Enum.filter(fn item ->
            item.type == :file and Parser.video_file?(item.name)
          end)

        episodes = scrape_anime_episodes_from_files(video_files, release_index)

        if Enum.empty?(episodes) do
          nil
        else
          %{
            season_number: release_index,
            name: folder.name,
            gindex_path: folder.path,
            episodes: episodes,
            episode_count: length(episodes),
            release_score: release_meta.score,
            release_group: release_meta.group,
            quality: release_meta.quality,
            is_dual: release_meta.is_dual
          }
        end

      {:error, reason} ->
        Logger.warning(
          "[GIndex Scraper] Failed to list release #{folder.name}: #{inspect(reason)}"
        )

        nil
    end
  end

  @doc """
  Scrapes episodes from a list of video files for anime.
  """
  def scrape_anime_episodes_from_files(files, release_index) do
    files
    |> Enum.map(fn file ->
      episode_meta = Parser.parse_anime_episode(file.name)

      if episode_meta.episode do
        episode_id = Parser.path_to_stream_id(file.path)

        %{
          episode_id: episode_id,
          episode_num: episode_meta.episode,
          title: nil,
          name: file.name,
          season_number: release_index,
          container_extension: episode_meta.extension || "mkv",
          gindex_path: file.path,
          file_size: file.size
        }
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.episode_num)
  end

  # =============================================================================
  # Series Scraping Functions
  # =============================================================================

  @doc """
  Scrapes all series from a GIndex provider.

  Returns a list of series data with seasons and episodes.
  """
  def scrape_series(
        base_url,
        series_paths \\ ["/1:/Séries/Séries WEB-DL/", "/1:/Séries/Séries Misturado/"]
      ) do
    series_paths
    |> Enum.flat_map(fn path ->
      case scrape_series_folder(base_url, path) do
        {:ok, series_list} -> series_list
        {:error, _} -> []
      end
    end)
  end

  @doc """
  Scrapes series from a specific folder path.

  Returns {:ok, series_list} or {:error, reason}.
  Uses pagination to fetch ALL series from the folder.
  """
  def scrape_series_folder(base_url, series_path) do
    # Delay before listing series folder
    rate_limit_delay()
    Logger.info("[GIndex Scraper] Scraping series folder: #{series_path}")

    # Use list_folder_all to handle pagination and get ALL series
    case Client.list_folder_all(base_url, series_path) do
      {:ok, items} ->
        folders = Enum.filter(items, &(&1.type == :folder))
        Logger.info("[GIndex Scraper] Found #{length(folders)} series folders in #{series_path}")

        series_list =
          folders
          |> Enum.map(fn folder ->
            # scrape_single_series already has delay
            scrape_single_series(base_url, folder)
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, series_list}

      {:error, reason} ->
        Logger.warning(
          "[GIndex Scraper] Failed to list series folder #{series_path}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Scrapes a single series folder and extracts seasons and episodes.
  """
  def scrape_single_series(base_url, folder) do
    # Delay before request
    rate_limit_delay()
    Logger.debug("[GIndex Scraper] Scraping series: #{folder.name}")

    # Parse series folder name
    folder_meta = Parser.parse_series_folder(folder.name)
    series_id = Parser.path_to_stream_id(folder.path)

    # List contents (seasons/release folders)
    case Client.list_folder(base_url, folder.path) do
      {:ok, items} ->
        # Find season folders
        season_folders =
          Enum.filter(items, fn item ->
            item.type == :folder and season_folder?(item)
          end)

        # Scrape seasons
        seasons = scrape_seasons(base_url, season_folders, folder.path)

        if Enum.empty?(seasons) do
          nil
        else
          total_episodes = Enum.sum(Enum.map(seasons, & &1.episode_count))

          %{
            series_id: series_id,
            name: folder_meta.name,
            title: folder_meta.original_name,
            year: folder_meta.year,
            gindex_path: folder.path,
            seasons: seasons,
            season_count: length(seasons),
            episode_count: total_episodes
          }
        end

      {:error, reason} ->
        Logger.warning(
          "[GIndex Scraper] Failed to list series #{folder.name}: #{inspect(reason)}"
        )

        nil
    end
  end

  @doc """
  Scrapes seasons from a list of season folders.
  """
  def scrape_seasons(base_url, season_folders, series_path) do
    season_folders
    |> Enum.map(fn folder ->
      # scrape_single_season already has delay
      scrape_single_season(base_url, folder, series_path)
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.season_number)
  end

  @doc """
  Scrapes a single season folder.
  """
  def scrape_single_season(base_url, folder, _series_path) do
    # Delay before request
    rate_limit_delay()
    Logger.debug("[GIndex Scraper] Scraping season: #{folder.name}")

    # Parse season number
    season_meta = Parser.parse_season_folder(folder.name)
    season_number = season_meta.season_number

    # List episodes in the season folder
    case Client.list_folder(base_url, folder.path) do
      {:ok, items} ->
        # Find video files (episodes)
        episode_files =
          items
          |> Enum.filter(fn item ->
            item.type == :file and Parser.video_file?(item.name)
          end)

        episodes = scrape_episodes_from_files(base_url, episode_files, season_number)

        if Enum.empty?(episodes) do
          # No episodes directly in folder, check subfolders (release folders)
          check_season_subfolders(base_url, items, season_number)
        else
          %{
            season_number: season_number,
            name: folder.name,
            gindex_path: folder.path,
            episodes: episodes,
            episode_count: length(episodes)
          }
        end

      {:error, reason} ->
        Logger.warning(
          "[GIndex Scraper] Failed to list season #{folder.name}: #{inspect(reason)}"
        )

        nil
    end
  end

  @doc """
  Scrapes episodes from a list of video files.
  """
  def scrape_episodes_from_files(_base_url, files, season_number) do
    files
    |> Enum.map(fn file ->
      episode_meta = Parser.parse_episode_name(file.name)

      # Use parsed episode number or fallback to inferred position
      episode_num = episode_meta.episode || infer_episode_number(file.name)

      if episode_num do
        episode_id = Parser.path_to_stream_id(file.path)

        %{
          episode_id: episode_id,
          episode_num: episode_num,
          title: episode_meta.title,
          name: file.name,
          season_number: episode_meta.season || season_number,
          container_extension: episode_meta.extension || "mkv",
          gindex_path: file.path,
          file_size: file.size
        }
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.episode_num)
  end

  # =============================================================================
  # Movie Scraping Functions
  # =============================================================================

  @doc """
  Scrapes a single movie folder and extracts video files.
  """
  def scrape_movie_folder(base_url, folder) do
    # Delay BEFORE request to avoid rate limiting
    rate_limit_delay()
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
    rate_limit_delay()

    if movie do
      {[movie], %{state | current_folders: rest}}
    else
      scrape_next_movie(%{state | current_folders: rest})
    end
  end

  defp scrape_next_movie(%{categories: [category | rest_categories]} = state) do
    Logger.info("[GIndex Scraper] Processing category: #{category.name}")

    # Delay before fetching category contents to avoid rate limiting
    rate_limit_delay()

    # Use list_folder_all to handle pagination for movie categories
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
      rate_limit_delay()
      check_subfolder_for_video(base_url, subfolder, parent_path)
    end)
  end

  defp check_subfolder_for_video(base_url, subfolder, parent_path) do
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

  # =============================================================================
  # Series Helper Functions
  # =============================================================================

  # Checks if a folder looks like a season folder
  defp season_folder?(folder) do
    name = folder.name
    # Match patterns like "S01", "Season 1", or "Nome.S01.1080p..."
    Regex.match?(~r/^S\d{1,2}$/i, name) or
      Regex.match?(~r/^Season\s*\d{1,2}$/i, name) or
      Regex.match?(~r/\.S\d{1,2}\./i, name) or
      Regex.match?(~r/S\d{1,2}[^a-zA-Z]/i, name)
  end

  # Check season subfolders for episodes (handles nested release folders)
  defp check_season_subfolders(base_url, items, season_number) do
    subfolders = Enum.filter(items, &(&1.type == :folder))

    all_episodes =
      subfolders
      |> Enum.flat_map(&scrape_subfolder_episodes(base_url, &1, season_number))
      |> Enum.sort_by(& &1.episode_num)

    if Enum.empty?(all_episodes) do
      nil
    else
      first_subfolder = List.first(subfolders)

      %{
        season_number: season_number,
        name: first_subfolder && first_subfolder.name,
        gindex_path: first_subfolder && first_subfolder.path,
        episodes: all_episodes,
        episode_count: length(all_episodes)
      }
    end
  end

  defp scrape_subfolder_episodes(base_url, subfolder, season_number) do
    rate_limit_delay()

    case Client.list_folder(base_url, subfolder.path) do
      {:ok, sub_items} ->
        sub_items
        |> Enum.filter(&(&1.type == :file and Parser.video_file?(&1.name)))
        |> scrape_episodes_from_files(base_url, season_number)

      {:error, _} ->
        []
    end
  end

  # Infer episode number from filename when S01E01 pattern is not found
  defp infer_episode_number(filename) do
    # Try to find episode number in various formats
    cond do
      # E01 pattern
      match = Regex.run(~r/E(\d{1,3})/i, filename) ->
        match |> Enum.at(1) |> String.to_integer()

      # Episode 1 or Ep 1 pattern
      match = Regex.run(~r/(?:Episode|Ep)[\s._-]*(\d{1,3})/i, filename) ->
        match |> Enum.at(1) |> String.to_integer()

      # Number at start of filename (01.mkv, 01 - Title.mkv)
      match = Regex.run(~r/^(\d{1,3})[\s._-]/, filename) ->
        match |> Enum.at(1) |> String.to_integer()

      true ->
        nil
    end
  end

  # Rate limit helper: adds jitter to base delay to avoid detection patterns
  defp rate_limit_delay do
    jitter = :rand.uniform(@max_jitter)
    Process.sleep(@base_delay + jitter)
  end
end
