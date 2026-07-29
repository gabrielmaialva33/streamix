defmodule Streamix.Gindex.Sync.PathsTest do
  use ExUnit.Case, async: true

  alias Streamix.Gindex.Sync.Paths
  alias Streamix.Iptv.{Provider, ProviderDrive}

  test "uses stable catalog defaults when no drive override exists" do
    provider = %Provider{id: 1, drives: []}

    assert Paths.movies_path(provider) == "/1:/Filmes/"

    assert Paths.series_paths(provider) == [
             "/1:/Séries/Séries WEB-DL/",
             "/1:/Séries/Séries Misturado/"
           ]

    assert Paths.animes_path(provider) == "/0:/Animes/"
  end

  test "reads single path overrides from provider drives" do
    provider = %Provider{
      id: 1,
      drives: [
        %ProviderDrive{
          provider_id: 1,
          drive_type: "movies",
          metadata: %{"path" => "/movies/"}
        },
        %ProviderDrive{
          provider_id: 1,
          drive_type: "series",
          metadata: %{"path" => "/series/"}
        },
        %ProviderDrive{
          provider_id: 1,
          drive_type: "animes",
          metadata: %{"path" => "/animes/"}
        }
      ]
    }

    assert Paths.movies_path(provider) == "/movies/"
    assert Paths.series_paths(provider) == ["/series/"]
    assert Paths.animes_path(provider) == "/animes/"
  end

  test "preserves multiple configured series roots" do
    provider = %Provider{
      id: 1,
      drives: [
        %ProviderDrive{
          provider_id: 1,
          drive_type: "series",
          metadata: %{"paths" => ["/series/a/", "/series/b/"]}
        }
      ]
    }

    assert Paths.series_paths(provider) == ["/series/a/", "/series/b/"]
  end
end
