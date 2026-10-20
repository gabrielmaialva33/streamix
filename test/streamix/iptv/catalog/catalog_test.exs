defmodule Streamix.Iptv.CatalogTest do
  use Streamix.DataCase, async: false

  import Streamix.IptvFixtures

  alias Streamix.Cache
  alias Streamix.Iptv.{Catalog, Genre}
  alias Streamix.Repo

  setup do
    Cache.delete("catalog:genres:movies")
    Cache.delete("catalog:genres:series")

    on_exit(fn ->
      Cache.delete("catalog:genres:movies")
      Cache.delete("catalog:genres:series")
    end)

    :ok
  end

  describe "list_genres_for/1" do
    test "returns only canonical genres (slug not nil) with %{id, slug, name} ordered by volume then name" do
      provider = global_provider_fixture()
      m1 = movie_fixture(provider, %{name: "M1"})
      m2 = movie_fixture(provider, %{name: "M2"})

      drama = upsert_genre!("drama", "Drama", 7)
      acao = upsert_genre!("acao", "Ação", 1)
      comedia = upsert_genre!("comedia", "Comédia", 4)
      raw = Repo.insert!(%Genre{name: "raw-unmigrated", slug: nil, position: nil})

      Repo.insert_all("movie_genres", [
        %{movie_id: m1.id, genre_id: drama.id},
        %{movie_id: m2.id, genre_id: drama.id},
        %{movie_id: m1.id, genre_id: comedia.id},
        %{movie_id: m2.id, genre_id: acao.id},
        %{movie_id: m1.id, genre_id: raw.id}
      ])

      assert Catalog.list_genres_for(:movies) == [
               %{id: drama.id, slug: "drama", name: "Drama"},
               %{id: acao.id, slug: "acao", name: "Ação"},
               %{id: comedia.id, slug: "comedia", name: "Comédia"}
             ]
    end
  end

  describe "list_movies_by_genre/2" do
    test "matches exact slug or case-insensitive name so Ação never matches Animação" do
      provider = global_provider_fixture()

      action_movie =
        provider
        |> movie_fixture(%{name: "Action Movie", rating: Decimal.new("8.5")})
        |> Ecto.Changeset.change(%{stream_icon: "https://img.example.test/action.jpg"})
        |> Repo.update!()

      animation_movie =
        provider
        |> movie_fixture(%{name: "Animated Movie", rating: Decimal.new("9.0")})
        |> Ecto.Changeset.change(%{stream_icon: "https://img.example.test/anim.jpg"})
        |> Repo.update!()

      acao = upsert_genre!("acao", "Ação", 1)
      animacao = upsert_genre!("animacao", "Animação", 3)

      Repo.insert_all("movie_genres", [
        %{movie_id: action_movie.id, genre_id: acao.id},
        %{movie_id: animation_movie.id, genre_id: animacao.id}
      ])

      by_name = Catalog.list_movies_by_genre("Ação")
      assert Enum.map(by_name, & &1.id) == [action_movie.id]

      by_case = Catalog.list_movies_by_genre("ação")
      assert Enum.map(by_case, & &1.id) == [action_movie.id]

      by_slug = Catalog.list_movies_by_genre("acao")
      assert Enum.map(by_slug, & &1.id) == [action_movie.id]

      assert Catalog.list_movies_by_genre("Anima") == []
    end
  end

  defp upsert_genre!(slug, name, position) do
    Repo.insert!(
      %Genre{slug: slug, name: name, position: position},
      on_conflict: {:replace, [:name, :position]},
      conflict_target: :slug
    )
    |> then(fn _ -> Repo.get_by!(Genre, slug: slug) end)
  end
end
