defmodule Streamix.Iptv.Content.GindexMoviesTest do
  use Streamix.DataCase, async: false

  import Streamix.IptvFixtures

  alias Streamix.Cache
  alias Streamix.Cache.Keys
  alias Streamix.Catalog
  alias Streamix.Iptv.Genres

  setup do
    Cache.delete(Keys.gindex_genres(:movies))
    on_exit(fn -> Cache.delete(Keys.gindex_genres(:movies)) end)
    %{drive: global_provider_fixture(%{provider_type: :gindex})}
  end

  defp drive_movie(drive, attrs) do
    movie_fixture(
      drive,
      Map.merge(%{gindex_path: "/Filmes/#{System.unique_integer([:positive])}"}, attrs)
    )
  end

  test "one card per title, newest first and undated last", %{drive: drive} do
    raw = drive_movie(drive, %{name: "Casino Royale 2006 720p", tmdb_id: "36557", year: 2006})

    best =
      drive_movie(drive, %{
        name: "007 (2006) - Cassino Royale [2006] 1080p Dual Áudio",
        title: "007 - Cassino Royale",
        stream_icon: "https://img.test/casino.jpg",
        tmdb_id: "36557",
        year: 2006
      })

    newer = drive_movie(drive, %{name: "Duna Parte 2", tmdb_id: "693134", year: 2024})
    undated = drive_movie(drive, %{name: "#Alive", tmdb_id: nil, year: nil})

    ids = Catalog.list_gindex_movies(limit: 10) |> Enum.map(& &1.id)

    assert ids == [newer.id, best.id, undated.id]
    refute raw.id in ids
    assert Catalog.gindex_counts().movies == 3
    assert Enum.map(Catalog.list_gindex_movie_versions(best), & &1.id) == [raw.id]
    assert Catalog.list_gindex_movie_versions(undated) == []
  end

  test "filters by genre and counts each title once per genre", %{drive: drive} do
    drama = Genres.canonical_ids()["drama"]

    copies =
      for name <- ["Ainda Estou Aqui 1080p", "Ainda Estou Aqui 4K"],
          do: drive_movie(drive, %{name: name, tmdb_id: "1000837", year: 2024})

    other = drive_movie(drive, %{name: "Comédia", tmdb_id: "1", year: 2024})
    Repo.insert_all("movie_genres", Enum.map(copies, &%{movie_id: &1.id, genre_id: drama}))

    assert [%{id: id}] = Catalog.list_gindex_movies(genre: "drama")
    assert id in Enum.map(copies, & &1.id)
    refute other.id == id
    assert [%{slug: "drama", count: 1}] = Catalog.list_gindex_genres(:movies)
  end
end
