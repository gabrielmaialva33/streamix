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

  test "playback lookup only accepts movies owned by a Torrent provider" do
    provider = provider_fixture(user_fixture())
    movie = movie_fixture(provider)

    assert {:error, :not_found} = Iptv.get_torrent_movie_for_playback(movie.id)
  end
end
