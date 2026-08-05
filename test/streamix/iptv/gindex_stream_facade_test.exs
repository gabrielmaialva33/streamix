defmodule Streamix.Iptv.GindexStreamFacadeTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv
  alias Streamix.Iptv.{Episode, Season}

  import Streamix.IptvFixtures

  setup do
    provider =
      global_provider_fixture(%{
        provider_type: :gindex,
        gindex_url: "https://stream.gindex.example"
      })

    %{provider: provider}
  end

  test "returns and updates the movie stream projection", %{provider: provider} do
    movie = movie_fixture(provider, %{gindex_path: "/1:/Movies/example.mkv"})

    assert {:ok, source} = Iptv.get_gindex_stream_source(:movie, movie.id)

    assert source == %{
             base_url: "https://stream.gindex.example",
             path: "/1:/Movies/example.mkv",
             cached_url: nil,
             cached_until: nil
           }

    expires_at = ~U[2026-08-04 15:30:00Z]
    assert :ok = Iptv.put_gindex_stream_cache(:movie, movie.id, "https://cdn/movie", expires_at)

    assert {:ok, %{cached_url: "https://cdn/movie", cached_until: ^expires_at}} =
             Iptv.get_gindex_stream_source(:movie, movie.id)
  end

  test "returns and updates the episode stream projection", %{provider: provider} do
    series = series_content_fixture(provider, %{gindex_path: "/1:/Series/example/"})

    season =
      %Season{}
      |> Season.changeset(%{series_id: series.id, season_number: 1, name: "Season 1"})
      |> Repo.insert!()

    catalog_item = catalog_item_fixture("episode", provider.id)

    episode =
      %Episode{}
      |> Episode.changeset(%{
        season_id: season.id,
        episode_id: 101,
        episode_num: 1,
        name: "Pilot",
        gindex_path: "/1:/Series/example/S01E01.mkv",
        catalog_item_id: catalog_item.id
      })
      |> Repo.insert!()

    assert {:ok, source} = Iptv.get_gindex_stream_source(:episode, episode.id)
    assert source.base_url == "https://stream.gindex.example"
    assert source.path == "/1:/Series/example/S01E01.mkv"

    expires_at = ~U[2026-08-04 16:30:00Z]

    assert :ok =
             Iptv.put_gindex_stream_cache(
               :episode,
               episode.id,
               "https://cdn/episode",
               expires_at
             )

    assert {:ok, %{cached_url: "https://cdn/episode", cached_until: ^expires_at}} =
             Iptv.get_gindex_stream_source(:episode, episode.id)
  end

  test "returns explicit boundary errors", %{provider: provider} do
    movie = movie_fixture(provider)

    assert {:error, :not_gindex_movie} = Iptv.get_gindex_stream_source(:movie, movie.id)
    assert {:error, :movie_not_found} = Iptv.get_gindex_stream_source(:movie, -1)
    assert {:error, :episode_not_found} = Iptv.get_gindex_stream_source(:episode, -1)
    assert {:error, :unsupported_type} = Iptv.get_gindex_stream_source(:channel, movie.id)

    assert {:error, :invalid_cache} =
             Iptv.put_gindex_stream_cache(:movie, movie.id, "", DateTime.utc_now())
  end
end
