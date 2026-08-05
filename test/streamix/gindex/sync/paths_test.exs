defmodule Streamix.Gindex.Sync.PathsTest do
  use ExUnit.Case, async: true

  alias Streamix.Gindex.Sync.Paths

  test "uses stable catalog defaults when no drive override exists" do
    source = %{drives: []}

    assert Paths.movies_path(source) == "/1:/Filmes/"

    assert Paths.series_paths(source) == [
             "/1:/Séries/Séries WEB-DL/",
             "/1:/Séries/Séries Misturado/"
           ]

    assert Paths.animes_path(source) == "/0:/Animes/"
  end

  test "reads single path overrides from provider drives" do
    source = %{
      drives: [
        %{
          kind: "movies",
          metadata: %{"path" => "/movies/"}
        },
        %{
          kind: "series",
          metadata: %{"path" => "/series/"}
        },
        %{
          kind: "animes",
          metadata: %{"path" => "/animes/"}
        }
      ]
    }

    assert Paths.movies_path(source) == "/movies/"
    assert Paths.series_paths(source) == ["/series/"]
    assert Paths.animes_path(source) == "/animes/"
  end

  test "preserves multiple configured series roots" do
    source = %{
      drives: [
        %{
          kind: "series",
          metadata: %{"paths" => ["/series/a/", "/series/b/"]}
        }
      ]
    }

    assert Paths.series_paths(source) == ["/series/a/", "/series/b/"]
  end
end
