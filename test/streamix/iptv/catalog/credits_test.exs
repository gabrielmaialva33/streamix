defmodule Streamix.Iptv.CreditsTest do
  use Streamix.DataCase, async: true

  import Streamix.IptvFixtures

  alias Streamix.Catalog
  alias Streamix.Iptv.Credits

  setup do
    provider = global_provider_fixture()
    id = fn -> Integer.to_string(System.unique_integer([:positive])) end

    directed = movie_fixture(provider, %{title: "Dirigido", tmdb_id: id.()})
    starred = movie_fixture(provider, %{title: "Estrelado", tmdb_id: id.()})
    extra = movie_fixture(provider, %{title: "Figurante", tmdb_id: id.()})
    show = series_content_fixture(provider, %{title: "Série", tmdb_id: id.()})

    credit(:movies, directed, "Zelda Quintanilha", "director", 0)
    credit(:movies, starred, "Zelda Quintanilha", "cast", 1)
    credit(:movies, extra, "Zelda Quintanilha", "cast", 12)
    credit(:series, show, "Zelda Quintanilha", "writer", 0)
    credit(:movies, extra, "Ana Zelda Quintanilha", "cast", 0)

    %{directed: directed, starred: starred, extra: extra, show: show}
  end

  test "names in the text resolve to their directed, written and billed titles", ctx do
    found = Credits.titles_by_people("filmes da zelda quintanilha")

    assert found.people == ["Zelda Quintanilha"]
    # Director first; a cast credit beyond the first eight does not count.
    assert found.movies == [variant(ctx.directed), variant(ctx.starred)]
    assert found.series == [variant(ctx.show)]
  end

  test "the longest name wins and one word is never a name", ctx do
    assert Credits.titles_by_people("ana zelda quintanilha").people == ["Ana Zelda Quintanilha"]
    assert Credits.titles_by_people("ana zelda quintanilha").movies == [variant(ctx.extra)]
    assert Credits.titles_by_people("quintanilha") == %{people: [], movies: [], series: []}
    assert Credits.titles_by_people(nil) == %{people: [], movies: [], series: []}
  end

  defp credit(kind, content, name, role, position) do
    {:ok, _} =
      Catalog.apply_tmdb_metadata(kind, content.tmdb_id, %{
        keywords: [],
        credits: [%{name: name, role: role, position: position}]
      })
  end

  defp variant(content), do: "tmdb:" <> content.tmdb_id
end
