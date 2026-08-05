defmodule Streamix.Gindex.Sync.NormalizersTest do
  use ExUnit.Case, async: true

  alias Streamix.Gindex.Sync.Normalizers.Episode
  alias Streamix.Gindex.Sync.Normalizers.Movie
  alias Streamix.Gindex.Sync.Normalizers.Season
  alias Streamix.Gindex.Sync.Normalizers.Series

  describe "Movie.attrs/1" do
    test "maps parsed GIndex movie data into the IPTV ingest contract" do
      movie = %{
        stream_id: "gindex-movie-1",
        name: "The Example",
        title: "The Example",
        year: 2025,
        container_extension: "mkv",
        gindex_path: "/1:/Filmes/The Example (2025).mkv"
      }

      attrs = Movie.attrs(movie)

      assert attrs == %{
               stream_id: "gindex-movie-1",
               name: "The Example",
               title: "The Example",
               year: 2025,
               container_extension: "mkv",
               gindex_path: "/1:/Filmes/The Example (2025).mkv"
             }
    end
  end

  describe "Series.attrs/1" do
    test "maps parsed GIndex series data into the IPTV ingest contract" do
      data = %{
        series_id: "series-1",
        name: "Example Series",
        title: "Example Series",
        year: 2024,
        gindex_path: "/1:/Series/Example Series/"
      }

      attrs = Series.attrs(data)

      assert attrs == %{
               series_id: "series-1",
               name: "Example Series",
               title: "Example Series",
               year: 2024,
               gindex_path: "/1:/Series/Example Series/"
             }
    end
  end

  describe "Season.attrs/1" do
    test "maps parsed GIndex season data into the IPTV ingest contract" do
      season_data = %{season_number: 2, name: "Second Season", episode_count: 10}

      attrs = Season.attrs(season_data)

      assert attrs == %{
               season_number: 2,
               name: "Second Season",
               episode_count: 10
             }
    end

    test "uses a deterministic season name when parsed name is missing" do
      attrs = Season.attrs(%{season_number: 3, name: nil, episode_count: 8})

      assert attrs.name == "Season 3"
      assert attrs.episode_count == 8
    end
  end

  describe "Episode.attrs/1" do
    test "maps parsed GIndex episode data into the IPTV ingest contract" do
      episode = %{
        episode_id: "series-1-s01e02",
        episode_num: 2,
        title: "Episode Two",
        name: "S01E02 - Episode Two",
        container_extension: "mp4",
        gindex_path: "/1:/Series/Example/S01/Episode Two.mp4"
      }

      attrs = Episode.attrs(episode)

      assert attrs == %{
               episode_id: "series-1-s01e02",
               episode_num: 2,
               title: "Episode Two",
               name: "S01E02 - Episode Two",
               container_extension: "mp4",
               gindex_path: "/1:/Series/Example/S01/Episode Two.mp4"
             }
    end
  end
end
