defmodule StreamixWeb.Api.V1.SearchControllerTest do
  use StreamixWeb.ConnCase, async: false

  import Streamix.IptvFixtures

  alias Streamix.Iptv.Genre
  alias Streamix.Repo

  setup do
    original_api_keys = Application.get_env(:streamix, :api_keys, [])
    Application.put_env(:streamix, :api_keys, [])
    on_exit(fn -> Application.put_env(:streamix, :api_keys, original_api_keys) end)
    :ok
  end

  test "fallback movie and series search emit both genre and canonical genres array", %{
    conn: conn
  } do
    provider = global_provider_fixture()

    movie =
      provider
      |> movie_fixture(%{name: "Nebula Odyssey", title: "Nebula Odyssey", year: 2024})
      |> Ecto.Changeset.change(%{stream_icon: "https://img.example.test/nebula.jpg"})
      |> Repo.update!()

    series =
      provider
      |> series_content_fixture(%{
        name: "Nebula Chronicles",
        title: "Nebula Chronicles",
        year: 2024
      })
      |> Ecto.Changeset.change(%{cover: "https://img.example.test/nebula-series.jpg"})
      |> Repo.update!()

    acao =
      Repo.insert!(
        %Genre{slug: "acao", name: "Ação", position: 1},
        on_conflict: {:replace, [:name, :position]},
        conflict_target: :slug
      )
      |> then(fn _ -> Repo.get_by!(Genre, slug: "acao") end)

    drama =
      Repo.insert!(
        %Genre{slug: "drama", name: "Drama", position: 7},
        on_conflict: {:replace, [:name, :position]},
        conflict_target: :slug
      )
      |> then(fn _ -> Repo.get_by!(Genre, slug: "drama") end)

    Repo.insert_all("movie_genres", [
      %{movie_id: movie.id, genre_id: drama.id},
      %{movie_id: movie.id, genre_id: acao.id}
    ])

    Repo.insert_all("series_genres", [
      %{series_id: series.id, genre_id: drama.id}
    ])

    movie_resp = conn |> get(~p"/api/v1/search/movies?q=Nebula") |> json_response(200)
    [found_movie] = Enum.filter(movie_resp["movies"], &(&1["id"] == movie.id))

    assert found_movie["genre"] == "Ação, Drama"

    assert found_movie["genres"] == [
             %{"slug" => "acao", "name" => "Ação"},
             %{"slug" => "drama", "name" => "Drama"}
           ]

    series_resp = conn |> get(~p"/api/v1/search/series?q=Nebula") |> json_response(200)
    [found_series] = Enum.filter(series_resp["series"], &(&1["id"] == series.id))

    assert found_series["genre"] == "Drama"
    assert found_series["genres"] == [%{"slug" => "drama", "name" => "Drama"}]
  end
end
