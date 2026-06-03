defmodule Streamix.Gindex.Scraper.Series do
  @moduledoc """
  Series, season, and episode scraping workflow for GIndex providers.
  """

  require Logger

  alias Streamix.Cache
  alias Streamix.Gindex.{Client, Parser}
  alias Streamix.Gindex.Scraper.Seasons

  # Top-level series listing changes when new series folders are added.
  # 1h TTL: short enough not to lose new content for long, but enough to
  # avoid paying the discovery walk twice in back-to-back retries.
  @top_level_cache_ttl 60 * 60

  @default_series_paths ["/1:/Séries/Séries WEB-DL/", "/1:/Séries/Séries Misturado/"]

  def scrape_series(base_url, series_paths \\ @default_series_paths) do
    # Use reduce_while so the first folder failure halts the run with a
    # tagged error — Enum.flat_map was silently turning {:error, _} into
    # [], which masked Cloudflare Worker 500s as a successful sync of
    # zero series. Caller relies on this to surface the failure all the
    # way up to ScanRootWorker so Oban retries instead of pinning the
    # provider to sync_status=completed with empty counts.
    Enum.reduce_while(series_paths, {:ok, []}, fn path, {:ok, acc} ->
      case scrape_series_folder(base_url, path) do
        {:ok, list} -> {:cont, {:ok, acc ++ list}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  def scrape_series_folder(base_url, series_path) do
    Logger.info("[GIndex Scraper] Scraping series folder: #{series_path}")

    case list_series_folders(base_url, series_path) do
      {:ok, folders} ->
        Logger.info("[GIndex Scraper] Found #{length(folders)} series folders in #{series_path}")

        series_list =
          folders
          |> Enum.map(&scrape_single_series(base_url, &1))
          |> Enum.reject(&is_nil/1)

        {:ok, series_list}

      {:error, reason} ->
        Logger.warning(
          "[GIndex Scraper] Failed to list series folder #{series_path}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp list_series_folders(base_url, series_path) do
    key = "gindex:disc:series:" <> base_url <> ":" <> series_path

    case Cache.get(key) do
      nil ->
        with {:ok, items} <- Client.list_folder_all(base_url, series_path),
             folders = Enum.filter(items, &(&1.type == :folder)),
             true <- folders != [] do
          Cache.set(key, folders, @top_level_cache_ttl)
          {:ok, folders}
        else
          false -> {:ok, []}
          {:error, _} = err -> err
        end

      cached ->
        {:ok, cached}
    end
  end

  def scrape_single_series(base_url, folder) do
    Logger.debug("[GIndex Scraper] Scraping series: #{folder.name}")

    folder_meta = Parser.parse_series_folder(folder.name)
    series_id = Parser.path_to_stream_id(folder.path)

    case Client.list_folder(base_url, folder.path) do
      {:ok, items} ->
        seasons =
          items
          |> Enum.filter(fn item -> item.type == :folder and season_folder?(item) end)
          |> scrape_seasons(base_url, folder.path)

        if Enum.empty?(seasons) do
          nil
        else
          %{
            series_id: series_id,
            name: folder_meta.name,
            title: folder_meta.original_name,
            year: folder_meta.year,
            gindex_path: folder.path,
            seasons: seasons,
            season_count: length(seasons),
            episode_count: Enum.sum(Enum.map(seasons, & &1.episode_count))
          }
        end

      {:error, reason} ->
        Logger.warning(
          "[GIndex Scraper] Failed to list series #{folder.name}: #{inspect(reason)}"
        )

        nil
    end
  end

  def scrape_seasons(season_folders, base_url, series_path) when is_list(season_folders) do
    season_folders
    |> Enum.map(&scrape_single_season(base_url, &1, series_path))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.season_number)
  end

  def scrape_seasons(base_url, season_folders, series_path) when is_binary(base_url) do
    scrape_seasons(season_folders, base_url, series_path)
  end

  def scrape_single_season(base_url, folder, _series_path) do
    Logger.debug("[GIndex Scraper] Scraping season: #{folder.name}")

    season_number = Parser.parse_season_folder(folder.name).season_number

    case Client.list_folder(base_url, folder.path) do
      {:ok, items} ->
        episodes =
          items
          |> Enum.filter(fn item -> item.type == :file and Parser.video_file?(item.name) end)
          |> scrape_episodes_from_files(base_url, season_number)

        if Enum.empty?(episodes) do
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

  def scrape_episodes_from_files(files, _base_url, season_number) when is_list(files) do
    build_episodes(files, season_number)
  end

  def scrape_episodes_from_files(base_url, files, season_number) when is_binary(base_url) do
    scrape_episodes_from_files(files, base_url, season_number)
  end

  def season_folder?(folder), do: Seasons.season_folder?(folder)

  defp build_episodes(files, season_number) do
    files
    |> Enum.map(fn file ->
      episode_meta = Parser.parse_episode_name(file.name)
      episode_num = episode_meta.episode || infer_episode_number(file.name)

      if episode_num do
        %{
          episode_id: Parser.path_to_stream_id(file.path),
          episode_num: episode_num,
          title: episode_meta.title,
          name: file.name,
          season_number: episode_meta.season || season_number,
          container_extension: episode_meta.extension || "mkv",
          gindex_path: file.path,
          file_size: file.size
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.episode_num)
  end

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
    case Client.list_folder(base_url, subfolder.path) do
      {:ok, sub_items} ->
        sub_items
        |> Enum.filter(fn item -> item.type == :file and Parser.video_file?(item.name) end)
        |> build_episodes(season_number)

      {:error, _reason} ->
        []
    end
  end

  defp infer_episode_number(filename) do
    cond do
      match = Regex.run(~r/E(\d{1,3})/i, filename) ->
        match |> Enum.at(1) |> String.to_integer()

      match = Regex.run(~r/(?:Episode|Ep)[\s._-]*(\d{1,3})/i, filename) ->
        match |> Enum.at(1) |> String.to_integer()

      match = Regex.run(~r/^(\d{1,3})[\s._-]/, filename) ->
        match |> Enum.at(1) |> String.to_integer()

      true ->
        nil
    end
  end
end
