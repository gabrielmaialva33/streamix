defmodule Streamix.Gindex.Scraper.MoviesTest do
  use ExUnit.Case, async: true

  alias Streamix.Gindex.Scraper.Movies

  test "builds a movie from a video stored directly in a category" do
    file = %{
      name: "The.Movie.2023.1080p.WEB-DL.DUAL.mkv",
      path: "/1:/Filmes/2023/The.Movie.2023.1080p.WEB-DL.DUAL.mkv",
      size: 1_024
    }

    assert %{
             name: "The Movie",
             year: 2023,
             quality: "1080p",
             source: "WEB-DL",
             container_extension: "mkv",
             is_dual_audio: true,
             file_size: 1_024,
             gindex_folder_path: "/1:/Filmes/2023/",
             gindex_path: "/1:/Filmes/2023/The.Movie.2023.1080p.WEB-DL.DUAL.mkv"
           } = Movies.movie_from_direct_file(file, "/1:/Filmes/2023/")
  end
end
