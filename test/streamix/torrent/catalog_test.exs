defmodule Streamix.Torrent.CatalogTest do
  use Streamix.DataCase, async: false

  alias Streamix.Iptv.{CatalogItem, Movie, Provider}
  alias Streamix.Repo
  alias Streamix.Torrent.{Catalog, TorrentStream}

  setup do
    {:ok, provider} =
      %Provider{}
      |> Provider.changeset(%{
        name: "Torrent Aggregator (test)",
        url: "torrent://aggregator-test-#{System.unique_integer([:positive])}",
        provider_type: :torrent,
        is_system: true,
        visibility: :global,
        is_active: true
      })
      |> Repo.insert()

    {:ok, provider: provider}
  end

  describe "list_movies/1" do
    test "ranks by max seeders and badges quality + seeders", %{provider: provider} do
      weak = movie_fixture(provider, "Weak Swarm")
      strong = movie_fixture(provider, "Strong Swarm")

      stream_fixture(weak, seeders: 3, quality: "720p")
      stream_fixture(strong, seeders: 50, quality: "1080p")
      stream_fixture(strong, seeders: 10, quality: "2160p")

      assert [first, second] = Catalog.list_movies()
      assert first.id == strong.id
      assert first.torrent_seeders == 50
      assert first.torrent_quality == "2160p"
      assert second.id == weak.id
      assert second.torrent_seeders == 3
    end

    test "excludes movies without any torrent stream", %{provider: provider} do
      _orphan = movie_fixture(provider, "No Streams")
      seeded = movie_fixture(provider, "Has Stream")
      stream_fixture(seeded, seeders: 5, quality: "1080p")

      assert [only] = Catalog.list_movies()
      assert only.id == seeded.id
    end

    test "filters by search", %{provider: provider} do
      a = movie_fixture(provider, "Interstellar")
      b = movie_fixture(provider, "Tenet")
      stream_fixture(a, seeders: 5, quality: "1080p")
      stream_fixture(b, seeders: 5, quality: "1080p")

      assert [only] = Catalog.list_movies(search: "inter")
      assert only.id == a.id
    end

    test "returns [] when the provider is absent" do
      Repo.delete_all(TorrentStream)
      Repo.delete_all(from(m in Movie))
      Repo.delete_all(from p in Provider, where: p.provider_type == :torrent)

      assert Catalog.list_movies() == []
    end
  end

  describe "best_stream_for_movie/1" do
    test "returns the most-seeded stream", %{provider: provider} do
      movie = movie_fixture(provider, "Pick Best")
      stream_fixture(movie, seeders: 2, quality: "480p")
      best = stream_fixture(movie, seeders: 99, quality: "1080p")

      assert Catalog.best_stream_for_movie(movie.id).id == best.id
    end

    test "nil when no streams exist", %{provider: provider} do
      movie = movie_fixture(provider, "No Streams")
      assert Catalog.best_stream_for_movie(movie.id) == nil
    end
  end

  defp movie_fixture(provider, name) do
    {:ok, catalog_item} =
      %CatalogItem{}
      |> CatalogItem.changeset(%{content_type: "movie", provider_id: provider.id})
      |> Repo.insert()

    {:ok, movie} =
      %Movie{}
      |> Movie.changeset(%{
        stream_id: System.unique_integer([:positive]),
        name: name,
        title: name,
        provider_id: provider.id,
        catalog_item_id: catalog_item.id
      })
      |> Repo.insert()

    movie
  end

  defp stream_fixture(movie, opts) do
    hash =
      Integer.to_string(System.unique_integer([:positive]), 16)
      |> String.downcase()
      |> String.pad_trailing(40, "0")
      |> String.slice(0, 40)

    {:ok, stream} =
      %TorrentStream{}
      |> TorrentStream.changeset(%{
        info_hash: hash,
        magnet_uri: "magnet:?xt=urn:btih:#{hash}",
        source_slug: "test",
        movie_id: movie.id,
        seeders: Keyword.fetch!(opts, :seeders),
        quality: Keyword.fetch!(opts, :quality)
      })
      |> Repo.insert()

    stream
  end
end
