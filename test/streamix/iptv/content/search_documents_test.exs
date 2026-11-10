defmodule Streamix.Iptv.SearchDocumentsTest do
  use Streamix.DataCase, async: true

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  test "returns ordered movie projections scoped by provider and cursor" do
    user = user_fixture()
    provider = provider_fixture(user)
    other_provider = provider_fixture(user)

    first = movie_fixture(provider, %{title: "First"})
    second = movie_fixture(provider, %{title: "Second"})
    _other = movie_fixture(other_provider, %{title: "Other"})

    assert [document] =
             Streamix.Search.list_search_documents(:movies, provider.id, after_id: first.id)

    assert document.id == second.id
    assert document.title == "Second"
    assert document.provider_id == provider.id
    assert document.genres == nil
  end

  test "carries keywords, credits and the title's variant key" do
    provider = provider_fixture(user_fixture())
    tmdb_id = Integer.to_string(System.unique_integer([:positive]))
    movie = movie_fixture(provider, %{title: "Interestelar", tmdb_id: tmdb_id})

    {:ok, _} =
      Streamix.Catalog.apply_tmdb_metadata(:movies, tmdb_id, %{
        keywords: [%{id: 4379, name: "time travel"}, %{id: 3801, name: "space travel"}],
        credits: [
          %{name: "Matthew McConaughey", role: "cast", position: 0},
          %{name: "Christopher Nolan", role: "director", position: 0},
          %{name: "Jonathan Nolan", role: "writer", position: 0}
        ]
      })

    assert [document] = Streamix.Search.list_search_documents(:movies, provider.id)
    assert document.id == movie.id
    assert document.keywords == ["time travel", "space travel"]
    assert document.directors == ["Christopher Nolan"]
    assert document.writers == ["Jonathan Nolan"]
    assert document.cast == ["Matthew Mcconaughey"]
    assert document.variant_key == "tmdb:" <> tmdb_id
  end

  test "pages through the whole catalog in short queries" do
    provider = provider_fixture(user_fixture())
    movies = for n <- 1..5, do: movie_fixture(provider, %{title: "Filme #{n}"})

    documents = Streamix.Search.list_search_documents(:movies, provider.id, page_size: 2)

    assert Enum.map(documents, & &1.id) == Enum.map(movies, & &1.id)
  end

  test "excludes content owned by inactive providers" do
    user = user_fixture()
    provider = provider_fixture(user, %{is_active: false})
    _series = series_content_fixture(provider, %{title: "Hidden"})

    assert Streamix.Search.list_search_documents(:series, provider.id) == []
  end

  test "splits anime out of series the same way the catalog does" do
    user = user_fixture()
    provider = provider_fixture(user)

    anime =
      series_content_fixture(provider, %{
        title: "Anime Title",
        gindex_path: "/1:/Animes/Anime Title/"
      })

    series =
      series_content_fixture(provider, %{
        title: "Series Title",
        gindex_path: "/1:/Séries/Series Title/"
      })

    assert [anime_document] = Streamix.Search.list_search_documents(:animes, provider.id)
    assert anime_document.id == anime.id

    series_ids = Streamix.Search.list_search_documents(:series, provider.id) |> Enum.map(& &1.id)
    assert series.id in series_ids
    refute anime.id in series_ids
  end

  test "keeps series without a gindex path in the series collection" do
    user = user_fixture()
    provider = provider_fixture(user)

    series = series_content_fixture(provider, %{title: "Xtream Series"})

    assert [document] = Streamix.Search.list_search_documents(:series, provider.id)
    assert document.id == series.id
    assert Streamix.Search.list_search_documents(:animes, provider.id) == []
  end

  test "validates the indexing cursor at the context boundary" do
    assert_raise ArgumentError, fn ->
      Streamix.Search.list_search_documents(:movies, nil, after_id: -1)
    end
  end
end
