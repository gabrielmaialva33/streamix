defmodule Streamix.Iptv.TmdbMetadataTest do
  use Streamix.DataCase, async: true

  import Ecto.Query
  import Streamix.IptvFixtures

  alias Streamix.Iptv.{Category, TmdbMetadata}

  @metadata %{
    keywords: [%{id: 9_663, name: "sequel"}],
    credits: [
      %{name: "Lead Actor", role: "cast", position: 0},
      %{name: "The Director", role: "director", position: 0}
    ]
  }

  test "stamps every copy, and adult copies get the keywords but no credits" do
    provider = global_provider_fixture()
    tmdb_id = Integer.to_string(System.unique_integer([:positive]))
    movie = movie_fixture(provider, %{tmdb_id: tmdb_id})
    adult = movie_fixture(provider, %{tmdb_id: tmdb_id})
    other = movie_fixture(provider, %{tmdb_id: tmdb_id <> "1"})

    category =
      %Category{}
      |> Category.changeset(%{
        provider_id: provider.id,
        name: "Adultos",
        type: "vod",
        is_adult: true,
        external_id: Integer.to_string(System.unique_integer([:positive]))
      })
      |> Repo.insert!()

    Repo.insert_all("item_categories", [
      %{catalog_item_id: adult.catalog_item_id, category_id: category.id}
    ])

    assert {:ok, %{copies: 2, credits: 2}} =
             TmdbMetadata.apply_tmdb(:movies, tmdb_id, @metadata)

    assert Repo.reload!(movie).tmdb_keyword_ids == [9_663]
    assert Repo.reload!(adult).tmdb_keyword_ids == [9_663]
    assert Repo.reload!(other).tmdb_keyword_ids == nil
    assert credit_count(movie.id) == 2
    assert credit_count(adult.id) == 0

    # Applying the same answer again adds nothing.
    assert {:ok, %{copies: 2, credits: 0}} =
             TmdbMetadata.apply_tmdb(:movies, tmdb_id, @metadata)

    assert TmdbMetadata.keyword_names([9_663, 1]) == %{9_663 => "sequel"}
  end

  test "an empty answer still marks the copies as fetched" do
    provider = global_provider_fixture()
    tmdb_id = Integer.to_string(System.unique_integer([:positive]))
    series = series_content_fixture(provider, %{tmdb_id: tmdb_id})

    assert {:ok, %{copies: 1, credits: 0}} =
             TmdbMetadata.apply_tmdb(:series, tmdb_id, %{keywords: [], credits: []})

    assert Repo.reload!(series).tmdb_keyword_ids == []
  end

  defp credit_count(movie_id) do
    Repo.aggregate(from(c in "movie_credits", where: c.movie_id == ^movie_id), :count)
  end
end
