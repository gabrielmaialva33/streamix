defmodule Streamix.Iptv.AccessTest do
  use Streamix.DataCase, async: false

  import Streamix.IptvFixtures

  alias Streamix.{Catalog, Providers, Search}

  # A degraded provider must drop out of everything a viewer browses — the
  # browse API, home shelves, search, ranked hydration, the provider
  # directory — through the one `Access.browsable/2` condition, while a direct
  # lookup still resolves so playback can fail with an explicit error.
  setup do
    embedplay = global_provider_fixture(%{name: "Embedplay", provider_type: :embedplay})
    xtream = global_provider_fixture(%{name: "Xtream"})

    # Distinct titles: search collapses provider variants of one title.
    movie_attrs = %{
      plot: "A hacker learns the truth.",
      stream_icon: "https://image.tmdb.org/t/p/w342/poster.jpg",
      year: Date.utc_today().year
    }

    %{
      embedplay: embedplay,
      embedplay_movie:
        movie_fixture(
          embedplay,
          Map.merge(movie_attrs, %{name: "The Matrix", title: "The Matrix"})
        ),
      xtream_movie:
        movie_fixture(
          xtream,
          Map.merge(movie_attrs, %{name: "Matrix Reloaded", title: "Matrix Reloaded"})
        )
    }
  end

  defp browse_surfaces(ids) do
    %{
      browse_api: Catalog.list_public_catalog_movies([]),
      browse_api_by_type: Catalog.list_public_catalog_movies(provider_type: :embedplay),
      home_featured_shelf: Catalog.list_public_movies(limit: 50),
      new_releases: Catalog.list_new_releases(limit: 50),
      top_10: Catalog.list_top_10_movies(limit: 50),
      recent: Catalog.list_recent("movie", limit: 50),
      search: Search.search_public_movies("Matrix"),
      ranked_hydration: Catalog.list_public_movies_by_ids(ids)
    }
  end

  defp ids_on(surfaces) do
    Map.new(surfaces, fn {surface, movies} -> {surface, MapSet.new(movies, & &1.id)} end)
  end

  test "a degraded provider's movies disappear from every browse surface and come back on recovery",
       %{embedplay_movie: embedplay_movie, xtream_movie: xtream_movie} do
    ids = [embedplay_movie.id, xtream_movie.id]

    for {surface, seen} <- ids_on(browse_surfaces(ids)), surface != :browse_api_by_type do
      assert embedplay_movie.id in seen, "#{surface} should list the healthy provider's movie"
    end

    assert Catalog.count_public_catalog_movies(provider_type: :embedplay) == 1
    assert %{movies_count: 2} = Catalog.get_public_stats(refresh: true)

    {:ok, _provider} = Providers.mark_embedplay_degraded(:no_source_available)

    for {surface, seen} <- ids_on(browse_surfaces(ids)) do
      refute embedplay_movie.id in seen, "#{surface} still lists a degraded provider's movie"

      if surface != :browse_api_by_type do
        assert xtream_movie.id in seen, "#{surface} lost a healthy provider's movie"
      end
    end

    assert Catalog.count_public_catalog_movies(provider_type: :embedplay) == 0
    assert %{movies_count: 1} = Catalog.get_public_stats(refresh: true)
    assert {:movie, %{id: featured_id}} = Catalog.get_featured_content()
    assert featured_id == xtream_movie.id

    {:ok, _provider} = Providers.mark_embedplay_healthy()

    assert embedplay_movie.id in MapSet.new(Catalog.list_public_movies(limit: 50), & &1.id)
    assert Catalog.count_public_catalog_movies(provider_type: :embedplay) == 1
  end

  test "a degraded provider leaves the provider directory but its titles still resolve directly",
       %{embedplay: embedplay, embedplay_movie: embedplay_movie} do
    {:ok, _provider} = Providers.mark_embedplay_degraded(:resolver_outdated)

    user = Streamix.AccountsFixtures.user_fixture()

    refute embedplay.id in Enum.map(Providers.list_public_providers(), & &1.id)
    refute embedplay.id in Enum.map(Providers.list_visible_providers(user.id), & &1.id)

    assert %{id: id, provider: %{health_status: :degraded, is_active: true}} =
             Catalog.get_public_movie(embedplay_movie.id)

    assert id == embedplay_movie.id
  end

  test "the operator switch still hides a healthy provider", %{
    embedplay: embedplay,
    embedplay_movie: embedplay_movie
  } do
    {:ok, _provider} = Providers.update_provider(embedplay, %{is_active: false})

    refute embedplay_movie.id in MapSet.new(Catalog.list_public_catalog_movies([]), & &1.id)
    refute embedplay.id in Enum.map(Providers.list_public_providers(), & &1.id)
  end
end
