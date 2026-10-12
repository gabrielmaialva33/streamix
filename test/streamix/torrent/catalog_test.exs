defmodule Streamix.Torrent.CatalogTest do
  use Streamix.DataCase, async: false

  alias Streamix.Iptv.{CatalogItem, Category, Movie, Provider}
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
      refresh_stats(provider)

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
      refresh_stats(provider)

      assert [only] = Catalog.list_movies()
      assert only.id == seeded.id
      assert Catalog.count_movies() == 1
    end

    test "keeps movies whose current swarm has zero seeders", %{provider: provider} do
      dead = movie_fixture(provider, "Dead Swarm")
      stream_fixture(dead, seeders: 0, quality: "720p")
      refresh_stats(provider)

      assert [%{id: id, torrent_seeders: 0}] = Catalog.list_movies()
      assert id == dead.id
    end

    test "filters by search", %{provider: provider} do
      a = movie_fixture(provider, "Interstellar")
      b = movie_fixture(provider, "Tenet")
      stream_fixture(a, seeders: 5, quality: "1080p")
      stream_fixture(b, seeders: 5, quality: "1080p")
      refresh_stats(provider)

      assert [only] = Catalog.list_movies(search: "inter")
      assert only.id == a.id
    end

    test "hides adult-category movies unless explicitly enabled", %{provider: provider} do
      safe = movie_fixture(provider, "Family Movie")
      adult = movie_fixture(provider, "Adult Movie")
      stream_fixture(safe, seeders: 5, quality: "1080p")
      stream_fixture(adult, seeders: 10, quality: "1080p")

      {:ok, category} =
        %Category{}
        |> Category.changeset(%{
          external_id: "adult",
          name: "Adult",
          type: "vod",
          provider_id: provider.id,
          is_adult: true
        })
        |> Repo.insert()

      Repo.insert_all("item_categories", [
        %{catalog_item_id: adult.catalog_item_id, category_id: category.id}
      ])

      refresh_stats(provider)

      assert Enum.map(Catalog.list_movies(), & &1.id) == [safe.id]
      assert Enum.map(Catalog.list_movies(show_adult: true), & &1.id) == [adult.id, safe.id]
      assert Catalog.count_movies() == 1
      assert Catalog.count_movies(show_adult: true) == 2
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

    test "prefers a clean release over a bigger swarm of fan dubs or cams", %{provider: provider} do
      movie = movie_fixture(provider, "Flagged Swarm")
      stream_fixture(movie, seeders: 500, quality: "1080p", release_flags: ["unofficial_dub"])
      stream_fixture(movie, seeders: 300, quality: "1080p", release_flags: ["cam"])
      clean = stream_fixture(movie, seeders: 4, quality: "720p")

      assert Catalog.best_stream_for_movie(movie.id).id == clean.id

      assert movie.id
             |> Catalog.streams_for_movie()
             |> Enum.map(&{&1.seeders, &1.release_flags}) == [
               {4, []},
               {500, ["unofficial_dub"]},
               {300, ["cam"]}
             ]
    end

    test "still plays a flagged release when nothing clean exists", %{provider: provider} do
      movie = movie_fixture(provider, "Only Cam")
      cam = stream_fixture(movie, seeders: 7, quality: "1080p", release_flags: ["cam"])

      assert Catalog.best_stream_for_movie(movie.id).id == cam.id
    end
  end

  describe "tmdb_ids_by_imdb/1" do
    test "returns only unambiguous IMDb to TMDB pairings", %{provider: provider} do
      movie_fixture(provider, "Matrix", imdb_id: "tt0133093", tmdb_id: "603")
      movie_fixture(provider, "Matrix (dup)", imdb_id: "tt0133093", tmdb_id: "603")
      movie_fixture(provider, "Clash A", imdb_id: "tt0000001", tmdb_id: "1")
      movie_fixture(provider, "Clash B", imdb_id: "tt0000001", tmdb_id: "2")
      movie_fixture(provider, "No TMDB", imdb_id: "tt0000002")

      assert Catalog.tmdb_ids_by_imdb(["tt0133093", "tt0000001", "tt0000002", "tt9999999"]) ==
               %{"tt0133093" => "603"}

      assert Catalog.tmdb_ids_by_imdb([]) == %{}
    end

    test "can ignore a provider's own (possibly fuzzy-matched) rows", %{provider: provider} do
      movie_fixture(provider, "Fuzzy", imdb_id: "tt0133093", tmdb_id: "603")

      assert Catalog.tmdb_ids_by_imdb(["tt0133093"], exclude_provider_id: provider.id) == %{}
      assert Catalog.tmdb_ids_by_imdb(["tt0133093"]) == %{"tt0133093" => "603"}
    end
  end

  defp movie_fixture(provider, name, attrs \\ []) do
    {:ok, catalog_item} =
      %CatalogItem{}
      |> CatalogItem.changeset(%{content_type: "movie", provider_id: provider.id})
      |> Repo.insert()

    {:ok, movie} =
      %Movie{}
      |> Movie.changeset(
        Map.merge(
          %{
            stream_id: System.unique_integer([:positive]),
            name: name,
            title: name,
            provider_id: provider.id,
            catalog_item_id: catalog_item.id
          },
          Map.new(attrs)
        )
      )
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
        quality: Keyword.fetch!(opts, :quality),
        release_flags: Keyword.get(opts, :release_flags, [])
      })
      |> Repo.insert()

    stream
  end

  defp refresh_stats(provider), do: :ok = Catalog.refresh_stats(provider.id)
end
