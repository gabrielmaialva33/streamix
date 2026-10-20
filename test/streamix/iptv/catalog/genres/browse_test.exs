defmodule Streamix.Iptv.Genres.BrowseTest do
  use Streamix.DataCase, async: false

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Cache
  alias Streamix.Cache.Keys
  alias Streamix.Catalog
  alias Streamix.Iptv.{Category, Genre, Genres, Provider}

  setup do
    user = user_fixture()
    other = user_fixture()
    ids = Genres.canonical_ids()

    keys =
      for kind <- [:movies, :series],
          viewer <- [nil, user.id, other.id],
          adult <- [false, true],
          do: Keys.visible_genres(kind, viewer, adult)

    Enum.each(keys, &Cache.delete/1)
    on_exit(fn -> Enum.each(keys, &Cache.delete/1) end)

    %{
      user: user,
      other: other,
      ids: ids,
      global: global_provider_fixture(),
      own: provider_fixture(user),
      private: provider_fixture(other)
    }
  end

  test "empty facets are cached and cache keys separate kind, user and adult scope", ctx do
    assert Catalog.list_visible_genres(:movies, ctx.user.id) == []
    row = item(:movies, ctx.global, "Added after cache fill")
    link(:movies, row, ctx.ids["drama"])
    assert Catalog.list_visible_genres(:movies, ctx.user.id) == []
    assert [%{slug: "drama", count: 1}] = Catalog.list_visible_genres(:movies, ctx.other.id)

    assert [%{slug: "drama", count: 1}] =
             Catalog.list_visible_genres(:movies, ctx.user.id, show_adult: true)

    assert Catalog.list_visible_genres(:series, ctx.user.id) == []
    Cache.delete(Keys.visible_genres(:movies, ctx.user.id, false))
    assert [%{slug: "drama", count: 1}] = Catalog.list_visible_genres(:movies, ctx.user.id)
  end

  for kind <- [:movies, :series] do
    @kind kind

    test "#{kind}: slug filtering precedes dedupe, search and pagination", ctx do
      first = item(@kind, ctx.global, "Alpha", %{tmdb_id: "100", year: 2020})
      copy = item(@kind, ctx.own, "Alpha 4K", %{tmdb_id: "100", year: 2020})
      second = item(@kind, ctx.own, "Beta", %{tmdb_id: "200", year: 2021})
      unrelated = item(@kind, ctx.global, "Aardvark")
      Enum.each([first, copy, second], &link(@kind, &1, ctx.ids["acao"]))
      link(@kind, unrelated, ctx.ids["drama"])

      rows = listing(@kind, ctx.user.id, genre: "acao", sort: "name_asc")
      assert length(rows) == 2
      assert Enum.map(rows, & &1.tmdb_id) == ["100", "200"]
      assert length(listing(@kind, ctx.user.id, genre: "acao", dedupe: false)) == 3

      assert [%{id: id}] =
               listing(@kind, ctx.user.id, genre: "acao", sort: "name_asc", limit: 1, offset: 1)

      assert id == second.id
      assert length(listing(@kind, ctx.user.id, genre: "acao", search: "Alpha")) == 1
      assert listing(@kind, ctx.user.id, genre: "unknown-slug") == []
      assert length(listing(@kind, ctx.user.id, genre: nil)) == 3
    end

    test "#{kind}: counts and filtering share provider and adult visibility", ctx do
      public = provider_fixture(ctx.other, %{visibility: :public})
      degraded = global_provider_fixture()
      inactive = global_provider_fixture()
      non_iptv = global_provider_fixture(%{provider_type: :gindex})

      Repo.update_all(from(p in Provider, where: p.id == ^degraded.id),
        set: [health_status: :degraded]
      )

      Repo.update_all(from(p in Provider, where: p.id == ^inactive.id), set: [is_active: false])

      for {provider, name} <- [
            {ctx.global, "Global"},
            {ctx.own, "Owned"},
            {ctx.private, "Private"},
            {public, "Public"},
            {degraded, "Degraded"},
            {inactive, "Inactive"},
            {non_iptv, "GIndex"}
          ] do
        link(@kind, item(@kind, provider, name), ctx.ids["acao"])
      end

      adult = item(@kind, ctx.global, "Adult")
      link(@kind, adult, ctx.ids["acao"])
      adult_category(@kind, ctx.global, adult)

      assert length(listing(@kind, ctx.user.id, genre: "acao")) == 3
      assert length(listing(@kind, ctx.user.id, genre: "acao", show_adult: true)) == 4
      assert [%{slug: "acao", count: 3}] = Catalog.list_visible_genres(@kind, ctx.user.id)

      assert [%{slug: "acao", count: 4}] =
               Catalog.list_visible_genres(@kind, ctx.user.id, show_adult: true)

      assert [%{slug: "acao", count: 2}] = Catalog.list_visible_genres(@kind, nil)
      assert [%{slug: "acao", count: 3}] = Catalog.list_visible_genres(@kind, ctx.other.id)
    end

    test "#{kind}: vocabulary order, distinct titles by TMDB id or name, canonical genres only",
         ctx do
      for {name, attrs} <- [
            {"Localized", %{tmdb_id: "700", year: 2020}},
            {"Outro nome", %{tmdb_id: "700", year: 2020}},
            {"Remake", %{tmdb_id: "701", year: 1990}},
            {"Remake", %{tmdb_id: "702", year: 2020}},
            {"No id", %{year: 2001}},
            {"no id", %{year: 2001}}
          ] do
        row = item(@kind, ctx.global, name, attrs)
        link(@kind, row, ctx.ids["drama"])
        link(@kind, row, ctx.ids["acao"])
      end

      raw = Repo.insert!(%Genre{name: "Unmapped"})
      link(@kind, item(@kind, ctx.global, "Raw only"), raw.id)

      # 700 (two names), 701, 702 and "no id" (case-folded) are four titles.
      assert [
               %{slug: "acao", name: "Ação", count: 4},
               %{slug: "drama", name: "Drama", count: 4}
             ] = Catalog.list_visible_genres(@kind, ctx.user.id)
    end
  end

  defp item(kind, provider, name, attrs \\ %{}) do
    attrs = Map.merge(%{name: name, title: name}, attrs)

    case kind do
      :movies -> movie_fixture(provider, attrs)
      :series -> series_content_fixture(provider, attrs)
    end
  end

  defp listing(:movies, user, opts), do: Catalog.list_visible_movies(user, opts)
  defp listing(:series, user, opts), do: Catalog.list_visible_series(user, opts)

  defp link(kind, item, genre_id) do
    {table, fk} =
      if kind == :movies, do: {"movie_genres", :movie_id}, else: {"series_genres", :series_id}

    Repo.insert_all(table, [%{fk => item.id, :genre_id => genre_id}])
  end

  defp adult_category(kind, provider, item) do
    category =
      Repo.insert!(%Category{
        provider_id: provider.id,
        name: "Adult",
        type: if(kind == :movies, do: "vod", else: "series"),
        external_id: "adult",
        is_adult: true
      })

    Repo.insert_all("item_categories", [
      %{catalog_item_id: item.catalog_item_id, category_id: category.id}
    ])
  end
end
