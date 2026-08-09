defmodule Streamix.Gindex.Scraper.Animes do
  @moduledoc """
  Anime scraping workflow for GIndex providers.
  """

  require Logger

  alias Streamix.Cache
  alias Streamix.Gindex.{Client, Parser}

  @top_level_cache_ttl 60 * 60

  def scrape_animes(base_url, anime_path \\ "/0:/Animes/") do
    Logger.info("[GIndex Scraper] Scraping animes from: #{anime_path}")

    case list_anime_folders(base_url, anime_path) do
      {:ok, folders} ->
        Logger.info("[GIndex Scraper] Found #{length(folders)} anime folders")
        collect_animes(base_url, folders)

      {:error, reason} = error ->
        Logger.warning(
          "[GIndex Scraper] Failed to list anime folder #{anime_path}: #{inspect(reason)}"
        )

        error
    end
  end

  defp collect_animes(base_url, folders) do
    folders
    |> Enum.sort_by(& &1.path)
    |> Enum.reduce_while({:ok, []}, fn folder, {:ok, acc} ->
      collect_anime(base_url, folder, acc)
    end)
    |> case do
      {:ok, animes} -> {:ok, Enum.reverse(animes)}
      {:error, _reason} = error -> error
    end
  end

  defp collect_anime(base_url, folder, acc) do
    case scrape_single_anime_result(base_url, folder) do
      {:ok, anime} -> {:cont, {:ok, [anime | acc]}}
      :empty -> {:cont, {:ok, acc}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  @doc false
  def list_anime_folders(base_url, anime_path) do
    key = "gindex:disc:animes:" <> base_url <> ":" <> anime_path

    case Cache.get(key) do
      nil ->
        with {:ok, items} <- Client.list_folder_all(base_url, anime_path),
             folders = Enum.filter(items, &(&1.type == :folder)),
             true <- folders != [] do
          Cache.set(key, folders, @top_level_cache_ttl)
          {:ok, folders}
        else
          false -> {:ok, []}
          {:error, _reason} = error -> error
        end

      cached ->
        {:ok, cached}
    end
  end

  def scrape_single_anime(base_url, folder) do
    case scrape_single_anime_result(base_url, folder) do
      {:ok, anime} -> anime
      :empty -> nil
      {:error, _reason} -> nil
    end
  end

  @doc false
  def scrape_single_anime_result(base_url, folder) do
    Logger.debug("[GIndex Scraper] Scraping anime: #{folder.name}")

    folder_meta = Parser.parse_anime_folder(folder.name)
    anime_id = Parser.path_to_stream_id(folder.path)

    with {:ok, items} <- Client.list_folder_with_failover(folder.path, base_url),
         release_folders = Enum.filter(items, &(&1.type == :folder)),
         {:ok, releases} <- scrape_anime_releases_result(base_url, release_folders) do
      if releases == [] do
        :empty
      else
        {:ok,
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
         }}
      end
    else
      {:error, reason} = error ->
        Logger.warning(
          "[GIndex Scraper] Failed to scrape anime #{folder.name}: #{inspect(reason)}"
        )

        error
    end
  end

  def scrape_anime_releases(release_folders, base_url) when is_list(release_folders) do
    case scrape_anime_releases_result(base_url, release_folders) do
      {:ok, releases} -> releases
      {:error, _reason} -> []
    end
  end

  def scrape_anime_releases(base_url, release_folders) when is_binary(base_url) do
    scrape_anime_releases(release_folders, base_url)
  end

  @doc false
  def scrape_anime_releases_result(base_url, release_folders) do
    release_folders
    |> Enum.sort_by(& &1.path)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {folder, index}, {:ok, acc} ->
      case scrape_single_anime_release_result(base_url, folder, index) do
        {:ok, release} -> {:cont, {:ok, [release | acc]}}
        :empty -> {:cont, {:ok, acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, releases} -> {:ok, Enum.sort_by(releases, & &1.release_score, :desc)}
      {:error, _reason} = error -> error
    end
  end

  def scrape_single_anime_release(base_url, folder, release_index) do
    case scrape_single_anime_release_result(base_url, folder, release_index) do
      {:ok, release} -> release
      :empty -> nil
      {:error, _reason} -> nil
    end
  end

  @doc false
  def scrape_single_anime_release_result(base_url, folder, release_index) do
    Logger.debug("[GIndex Scraper] Scraping anime release: #{folder.name}")

    release_meta = Parser.parse_release_folder(folder.name)

    case Client.list_folder_with_failover(folder.path, base_url) do
      {:ok, items} ->
        episodes =
          items
          |> Enum.filter(fn item -> item.type == :file and Parser.video_file?(item.name) end)
          |> scrape_anime_episodes_from_files(release_index)

        if episodes == [] do
          :empty
        else
          {:ok,
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
           }}
        end

      {:error, reason} = error ->
        Logger.warning(
          "[GIndex Scraper] Failed to list release #{folder.name}: #{inspect(reason)}"
        )

        error
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
end
