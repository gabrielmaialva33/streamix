defmodule Streamix.Gindex.Sync.MoviesTest do
  use Streamix.DataCase, async: true

  alias Streamix.Gindex.Sync.Movies
  alias Streamix.Iptv.{CatalogItem, Movie, Provider}
  alias Streamix.Repo

  test "deduplicates repeated stream ids before creating catalog items and upserting" do
    provider = gindex_provider()
    movie = movie_data(42)

    assert {:ok, 1} = Movies.upsert_batch(%{provider_id: provider.id}, [movie, movie])

    assert Repo.aggregate(Movie, :count) == 1

    assert Repo.aggregate(
             from(c in CatalogItem, where: c.provider_id == ^provider.id),
             :count
           ) == 1
  end

  defp gindex_provider do
    %Provider{}
    |> Provider.changeset(%{
      name: "GIndex Movie Sync Test",
      url: "https://gindex-movies.example.com",
      gindex_url: "https://gindex-movies.example.com",
      provider_type: :gindex,
      is_system: true,
      visibility: :global
    })
    |> Repo.insert!()
  end

  defp movie_data(stream_id) do
    %{
      stream_id: stream_id,
      name: "Duplicated Movie",
      title: "Duplicated Movie",
      year: 2026,
      container_extension: "mkv",
      gindex_path: "/1:/Filmes/2026/Duplicated Movie.mkv"
    }
  end
end
