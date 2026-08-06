defmodule Streamix.Gindex.Scraper do
  @moduledoc """
  Public facade for GIndex scraping workflows.
  """

  alias Streamix.Gindex.Scraper.{Animes, Movies, Series}

  def scrape_movies(base_url, movies_path \\ "/1:/Filmes/") do
    Movies.scrape_movies(base_url, movies_path)
  end

  def scrape_category(base_url, category_path),
    do: Movies.scrape_category(base_url, category_path)

  def list_categories(base_url, movies_path \\ "/1:/Filmes/") do
    Movies.list_categories(base_url, movies_path)
  end

  def scrape_movie_folder(base_url, folder), do: Movies.scrape_movie_folder(base_url, folder)

  def scrape_movie_folder_result(base_url, folder),
    do: Movies.scrape_movie_folder_result(base_url, folder)

  def movie_from_direct_file(video_file, category_path),
    do: Movies.movie_from_direct_file(video_file, category_path)

  def scrape_animes(base_url, anime_path \\ "/0:/Animes/") do
    Animes.scrape_animes(base_url, anime_path)
  end

  def list_anime_folders(base_url, anime_path),
    do: Animes.list_anime_folders(base_url, anime_path)

  def scrape_single_anime(base_url, folder), do: Animes.scrape_single_anime(base_url, folder)

  def scrape_single_anime_result(base_url, folder),
    do: Animes.scrape_single_anime_result(base_url, folder)

  def scrape_anime_releases(base_url, release_folders),
    do: Animes.scrape_anime_releases(base_url, release_folders)

  def scrape_single_anime_release(base_url, folder, release_index) do
    Animes.scrape_single_anime_release(base_url, folder, release_index)
  end

  def scrape_anime_episodes_from_files(files, release_index) do
    Animes.scrape_anime_episodes_from_files(files, release_index)
  end

  def scrape_series(
        base_url,
        series_paths \\ ["/1:/Séries/Séries WEB-DL/", "/1:/Séries/Séries Misturado/"]
      ) do
    Series.scrape_series(base_url, series_paths)
  end

  def scrape_series_folder(base_url, series_path),
    do: Series.scrape_series_folder(base_url, series_path)

  def list_series_folders(base_url, series_path),
    do: Series.list_series_folders(base_url, series_path)

  def scrape_single_series(base_url, folder), do: Series.scrape_single_series(base_url, folder)

  def scrape_single_series_result(base_url, folder),
    do: Series.scrape_single_series_result(base_url, folder)

  def scrape_seasons(base_url, season_folders, series_path),
    do: Series.scrape_seasons(base_url, season_folders, series_path)

  def scrape_single_season(base_url, folder, series_path) do
    Series.scrape_single_season(base_url, folder, series_path)
  end

  def scrape_episodes_from_files(base_url, files, season_number) do
    Series.scrape_episodes_from_files(base_url, files, season_number)
  end

  def season_folder?(folder), do: Series.season_folder?(folder)
end
