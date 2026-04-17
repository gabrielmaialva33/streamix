defmodule Streamix.Iptv.Content.TmdbAssetsPersistenceTest do
  @moduledoc """
  Regression for the TMDB asset persistence pipeline.

  TmdbClient.parse_{movie,series}_response/1 emits :_backdrop_urls and
  :_image_urls. These are *not* Movie/Series schema fields, so if the
  enrichment path forgets to extract them, they get silently dropped by
  cast/3 and the UI falls back to the poster for the hero image.

  These tests exercise the persist helpers directly so we don't depend on
  stubbing HTTP.
  """

  use Streamix.DataCase, async: true

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv.{CatalogItem, Movies, MovieAsset, Series, SeriesAsset, SeriesOps}
  alias Streamix.Repo

  setup do
    provider = provider_fixture(user_fixture())
    {:ok, provider: provider}
  end

  describe "Movies.persist_movie_assets/3" do
    test "stores backdrop URLs with stable positions", %{provider: provider} do
      movie = movie_fixture(provider)

      urls = [
        "https://cdn.example/backdrops/a.jpg",
        "https://cdn.example/backdrops/b.jpg",
        "https://cdn.example/backdrops/c.jpg"
      ]

      assert Movies.persist_movie_assets(movie.id, "backdrop", urls) == :ok

      assets =
        MovieAsset
        |> Repo.all()
        |> Enum.filter(&(&1.movie_id == movie.id and &1.asset_type == "backdrop"))
        |> Enum.sort_by(& &1.position)

      assert Enum.map(assets, & &1.url) == urls
      assert Enum.map(assets, & &1.position) == [0, 1, 2]
    end

    test "re-syncing replaces the existing set", %{provider: provider} do
      movie = movie_fixture(provider)

      :ok = Movies.persist_movie_assets(movie.id, "backdrop", ["url-old-1", "url-old-2"])
      :ok = Movies.persist_movie_assets(movie.id, "backdrop", ["url-new"])

      assets =
        MovieAsset
        |> Repo.all()
        |> Enum.filter(&(&1.movie_id == movie.id and &1.asset_type == "backdrop"))

      assert Enum.map(assets, & &1.url) == ["url-new"]
    end

    test "empty list and nil are no-op", %{provider: provider} do
      movie = movie_fixture(provider)

      assert Movies.persist_movie_assets(movie.id, "backdrop", []) == :ok
      assert Movies.persist_movie_assets(movie.id, "image", nil) == :ok

      assert Repo.all(MovieAsset) == []
    end

    test "filters out nil and empty strings", %{provider: provider} do
      movie = movie_fixture(provider)

      :ok =
        Movies.persist_movie_assets(movie.id, "image", [
          "https://cdn.example/good.jpg",
          nil,
          "",
          "https://cdn.example/also-good.jpg"
        ])

      urls =
        MovieAsset
        |> Repo.all()
        |> Enum.filter(&(&1.movie_id == movie.id))
        |> Enum.sort_by(& &1.position)
        |> Enum.map(& &1.url)

      assert urls == ["https://cdn.example/good.jpg", "https://cdn.example/also-good.jpg"]
    end
  end

  describe "SeriesOps.persist_series_assets/3" do
    test "stores backdrops and images independently", %{provider: provider} do
      series = series_fixture_for(provider)

      :ok = SeriesOps.persist_series_assets(series.id, "backdrop", ["b1", "b2"])
      :ok = SeriesOps.persist_series_assets(series.id, "image", ["i1", "i2", "i3"])

      # Changing one type doesn't wipe the other.
      :ok = SeriesOps.persist_series_assets(series.id, "image", ["i-only"])

      assets =
        SeriesAsset
        |> Repo.all()
        |> Enum.filter(&(&1.series_id == series.id))
        |> Enum.group_by(& &1.asset_type, & &1.url)

      assert Enum.sort(assets["backdrop"]) == ["b1", "b2"]
      assert assets["image"] == ["i-only"]
    end
  end

  # Minimal series fixture — the existing IptvFixtures module exposes
  # provider_fixture and movie_fixture but not a series_fixture, so we
  # build one locally with just the required fields.
  defp series_fixture_for(provider) do
    catalog_item =
      %CatalogItem{}
      |> CatalogItem.changeset(%{content_type: "series", provider_id: provider.id})
      |> Repo.insert!()

    %Series{}
    |> Series.changeset(%{
      series_id: System.unique_integer([:positive]),
      name: "Test Series #{System.unique_integer([:positive])}",
      provider_id: provider.id,
      catalog_item_id: catalog_item.id
    })
    |> Repo.insert!()
  end
end
