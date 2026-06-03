defmodule Streamix.Gindex.Sync.NormalizersTest do
  use ExUnit.Case, async: true

  alias Streamix.Gindex.Sync.Normalizers.Episode
  alias Streamix.Gindex.Sync.Normalizers.Movie
  alias Streamix.Gindex.Sync.Normalizers.Season
  alias Streamix.Gindex.Sync.Normalizers.Series

  @provider %{id: 42}
  @now ~U[2026-05-06 08:30:00Z]

  describe "Movie.attrs/4" do
    test "maps parsed GIndex movie data into insert attrs" do
      movie = %{
        stream_id: "gindex-movie-1",
        name: "The Example",
        title: "The Example",
        year: 2025,
        container_extension: "mkv",
        gindex_path: "/1:/Filmes/The Example (2025).mkv"
      }

      attrs = Movie.attrs(movie, @provider, 123, @now)

      assert attrs == %{
               provider_id: 42,
               stream_id: "gindex-movie-1",
               name: "The Example",
               title: "The Example",
               year: 2025,
               container_extension: "mkv",
               gindex_path: "/1:/Filmes/The Example (2025).mkv",
               catalog_item_id: 123,
               inserted_at: @now,
               updated_at: @now
             }
    end
  end

  describe "Series.attrs/2" do
    test "maps parsed GIndex series data into schema attrs" do
      data = %{
        series_id: "series-1",
        name: "Example Series",
        title: "Example Series",
        year: 2024,
        gindex_path: "/1:/Series/Example Series/"
      }

      attrs = Series.attrs(data, @provider)

      assert attrs == %{
               provider_id: 42,
               series_id: "series-1",
               name: "Example Series",
               title: "Example Series",
               year: 2024,
               gindex_path: "/1:/Series/Example Series/"
             }
    end
  end

  describe "Season.attrs/2" do
    test "maps parsed GIndex season data into schema attrs" do
      series = %{id: 77}
      season_data = %{season_number: 2, name: "Second Season", episode_count: 10}

      attrs = Season.attrs(series, season_data)

      assert attrs == %{
               series_id: 77,
               season_number: 2,
               name: "Second Season",
               episode_count: 10
             }
    end

    test "uses a deterministic season name when parsed name is missing" do
      attrs = Season.attrs(%{id: 77}, %{season_number: 3, name: nil, episode_count: 8})

      assert attrs.name == "Season 3"
      assert attrs.series_id == 77
      assert attrs.episode_count == 8
    end
  end

  describe "Episode.attrs/4" do
    test "maps parsed GIndex episode data into insert attrs" do
      episode = %{
        episode_id: "series-1-s01e02",
        episode_num: 2,
        title: "Episode Two",
        name: "S01E02 - Episode Two",
        container_extension: "mp4",
        gindex_path: "/1:/Series/Example/S01/Episode Two.mp4"
      }

      attrs = Episode.attrs(episode, %{id: 88}, 456, @now)

      assert attrs == %{
               season_id: 88,
               episode_id: "series-1-s01e02",
               episode_num: 2,
               title: "Episode Two",
               name: "S01E02 - Episode Two",
               container_extension: "mp4",
               gindex_path: "/1:/Series/Example/S01/Episode Two.mp4",
               catalog_item_id: 456,
               inserted_at: @now,
               updated_at: @now
             }
    end
  end
end
