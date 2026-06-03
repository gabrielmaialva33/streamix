defmodule Streamix.Gindex.Scraper.Animes do
  @moduledoc """
  Anime scraping workflow for GIndex providers.
  """

  require Logger

  alias Streamix.Gindex.{Client, Parser}

  def scrape_animes(base_url, anime_path \\ "/0:/Animes/") do
    rate_limit_delay()
    Logger.info("[GIndex Scraper] Scraping animes from: #{anime_path}")

    case Client.list_folder_all(base_url, anime_path) do
      {:ok, items} ->
        folders = Enum.filter(items, &(&1.type == :folder))
        Logger.info("[GIndex Scraper] Found #{length(folders)} anime folders")

        animes =
          folders
          |> Enum.map(&scrape_single_anime(base_url, &1))
          |> Enum.reject(&is_nil/1)

        {:ok, animes}

      {:error, reason} ->
        Logger.warning(
          "[GIndex Scraper] Failed to list anime folder #{anime_path}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  def scrape_single_anime(base_url, folder) do
    rate_limit_delay()
    Logger.debug("[GIndex Scraper] Scraping anime: #{folder.name}")

    folder_meta = Parser.parse_anime_folder(folder.name)
    anime_id = Parser.path_to_stream_id(folder.path)

    case Client.list_folder(base_url, folder.path) do
      {:ok, items} ->
        releases =
          items
          |> Enum.filter(&(&1.type == :folder))
          |> scrape_anime_releases(base_url)

        if Enum.empty?(releases) do
          nil
        else
          %{
            series_id: anime_id,
            name: folder_meta.name,
            title: folder_meta.original_name,
            year: folder_meta.year,
            gindex_path: folder.path,
            seasons: releases,
            season_count: length(releases),
            episode_count: Enum.sum(Enum.map(releases, & &1.episode_count)),
            content_type: "anime"
          }
        end

      {:error, reason} ->
        Logger.warning("[GIndex Scraper] Failed to list anime #{folder.name}: #{inspect(reason)}")
        nil
    end
  end

  def scrape_anime_releases(release_folders, base_url) when is_list(release_folders) do
    release_folders
    |> Enum.with_index(1)
    |> Enum.map(fn {folder, index} -> scrape_single_anime_release(base_url, folder, index) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.release_score, :desc)
  end

  def scrape_anime_releases(base_url, release_folders) when is_binary(base_url) do
    scrape_anime_releases(release_folders, base_url)
  end

  def scrape_single_anime_release(base_url, folder, release_index) do
    rate_limit_delay()
    Logger.debug("[GIndex Scraper] Scraping anime release: #{folder.name}")

    release_meta = Parser.parse_release_folder(folder.name)

    case Client.list_folder(base_url, folder.path) do
      {:ok, items} ->
        episodes =
          items
          |> Enum.filter(fn item -> item.type == :file and Parser.video_file?(item.name) end)
          |> scrape_anime_episodes_from_files(release_index)

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

  def scrape_anime_episodes_from_files(files, release_index) do
    files
    |> Enum.map(fn file ->
      episode_meta = Parser.parse_anime_episode(file.name)

      if episode_meta.episode do
        %{
          episode_id: Parser.path_to_stream_id(file.path),
          episode_num: episode_meta.episode,
          title: nil,
          name: file.name,
          season_number: release_index,
          container_extension: episode_meta.extension || "mkv",
          gindex_path: file.path,
          file_size: file.size
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.episode_num)
  end

  defp rate_limit_delay, do: :ok
end
