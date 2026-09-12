defmodule Streamix.Iptv.TorrentMoviesFacadeTest do
  use Streamix.DataCase, async: true

  alias Streamix.Iptv

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  test "upserts a torrent movie without accepting cross-boundary ownership fields" do
    provider =
      global_provider_fixture(%{
        provider_type: :torrent,
        url: "torrent://movie-ingest"
      })

    other_provider = provider_fixture(user_fixture())

    attrs = %{
      stream_id: 123,
      name: "Boundary Movie",
      title: "Boundary Movie",
      year: 2026,
      rating: Decimal.new("8.4"),
      provider_id: other_provider.id,
      catalog_item_id: -1
    }

    assert {:ok, movie_id} = Iptv.upsert_torrent_movie(provider.id, attrs)

    movie = Iptv.get_movie!(movie_id)
    assert movie.provider_id == provider.id
    assert movie.catalog_item_id
    assert movie.title == "Boundary Movie"

    assert {:ok, ^movie_id} =
             Iptv.upsert_torrent_movie(provider.id, %{attrs | title: "Boundary Movie Updated"})

    assert Iptv.get_movie!(movie_id).title == "Boundary Movie Updated"
  end

  test "torrent metadata accepts useful values but omits blank changes before casting" do
    provider = global_provider_fixture(%{provider_type: :torrent})
    identity = %{stream_id: 550, name: "Source name"}

    metadata = %{
      title: "Enriched title",
      year: 1999,
      rating: Decimal.new("8.5"),
      stream_icon: "https://images.example.com/poster.jpg",
      plot: "Enriched plot",
      tmdb_id: "550",
      imdb_id: "tt0137523",
      duration_secs: 7200
    }

    assert {:ok, movie_id} = Iptv.upsert_torrent_movie(provider.id, identity)

    assert {:ok, ^movie_id} =
             Iptv.upsert_torrent_movie(provider.id, Map.merge(identity, metadata))

    assert Map.take(Iptv.get_movie!(movie_id), Map.keys(metadata)) == metadata

    for blank <- [nil, "", "   "] do
      attrs = Map.new(metadata, fn {key, _value} -> {key, blank} end)
      attrs = Map.merge(attrs, %{identity | name: "Updated source name"})
      assert {:ok, ^movie_id} = Iptv.upsert_torrent_movie(provider.id, attrs)
      reloaded = Iptv.get_movie!(movie_id)
      assert Map.take(reloaded, Map.keys(metadata)) == metadata
      assert reloaded.name == "Updated source name"
      assert reloaded.stream_id == 550
    end

    for empty_id <- ["0", 0] do
      assert {:ok, ^movie_id} =
               Iptv.upsert_torrent_movie(provider.id, Map.put(identity, :tmdb_id, empty_id))

      assert Iptv.get_movie!(movie_id).tmdb_id == "550"
    end

    assert {:ok, ^movie_id} =
             Iptv.upsert_torrent_movie(provider.id, Map.put(identity, :plot, "New source plot"))

    assert Iptv.get_movie!(movie_id).plot == "New source plot"
    assert {:error, _changeset} = Iptv.upsert_torrent_movie(provider.id, %{identity | name: nil})
  end

  test "playback lookup only accepts movies owned by a Torrent provider" do
    provider = provider_fixture(user_fixture())
    movie = movie_fixture(provider)

    assert {:error, :not_found} = Iptv.get_torrent_movie_for_playback(movie.id)
  end
end
