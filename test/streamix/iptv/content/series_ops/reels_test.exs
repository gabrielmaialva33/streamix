defmodule Streamix.Iptv.Content.SeriesOps.ReelsTest do
  use Streamix.DataCase, async: true

  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Catalog
  alias Streamix.Iptv.Category

  setup do
    user = user_fixture()
    global = global_provider_fixture(%{name: "MegaEmbed"})

    %{user: user, global: global}
  end

  describe "list_visible_reel_series/2" do
    test "lists only series tagged with a [Reels] category", %{user: user, global: global} do
      asia = category!(global, "[Reels] Histórias da Ásia")
      drama = reel!(global, [asia], %{name: "Amor em Seul"})
      _regular = series_content_fixture(global, %{name: "Regular Show"})

      assert ids(Catalog.list_visible_reel_series(user.id)) == [drama.id]
    end

    test "matches the literal prefix only", %{user: user, global: global} do
      _lowercase = reel!(global, [category!(global, "[reels] Minúsculo")])
      _no_brackets = reel!(global, [category!(global, "Reels Lançamentos")])
      _infix = reel!(global, [category!(global, "Novelas [Reels] Curtas")])
      _vod = reel!(global, [category!(global, "[Reels] Filmes", "vod")])
      _unnamed = reel!(global, [category!(global, "[Reels]  ")])
      kept = reel!(global, [category!(global, "[Reels] Lançamentos")])

      assert ids(Catalog.list_visible_reel_series(user.id)) == [kept.id]

      assert Catalog.list_visible_reel_categories(user.id) == [
               %{name: "Lançamentos", count: 1}
             ]
    end

    test "applies provider visibility, operator and health switches", %{
      user: user,
      global: global
    } do
      other_user = user_fixture()
      own = provider_fixture(user, %{name: "Own"})
      public = provider_fixture(other_user, %{name: "Public", visibility: :public})
      private = provider_fixture(other_user, %{name: "Private"})
      inactive = global_provider_fixture(%{name: "Inactive"})
      degraded = global_provider_fixture(%{name: "Degraded"})

      global_reel = reel!(global, [category!(global, "[Reels] Lançamentos")])
      own_reel = reel!(own, [category!(own, "[Reels] Lançamentos")])
      public_reel = reel!(public, [category!(public, "[Reels] Lançamentos")])
      _private_reel = reel!(private, [category!(private, "[Reels] Lançamentos")])
      _inactive_reel = reel!(inactive, [category!(inactive, "[Reels] Lançamentos")])
      _degraded_reel = reel!(degraded, [category!(degraded, "[Reels] Lançamentos")])

      inactive |> Ecto.Changeset.change(is_active: false) |> Repo.update!()
      degraded |> Ecto.Changeset.change(health_status: :degraded) |> Repo.update!()

      assert MapSet.new(ids(Catalog.list_visible_reel_series(user.id))) ==
               MapSet.new([global_reel.id, own_reel.id, public_reel.id])

      assert Catalog.list_visible_reel_categories(user.id) == [
               %{name: "Lançamentos", count: 3}
             ]
    end

    test "excludes adult titles unless the user opts in", %{user: user, global: global} do
      reels = category!(global, "[Reels] Relacionamento Tabu")
      adult = category!(global, "Adultos", "series", true)
      safe = reel!(global, [reels])
      explicit = reel!(global, [reels, adult])

      assert ids(Catalog.list_visible_reel_series(user.id)) == [safe.id]

      assert Catalog.list_visible_reel_categories(user.id) == [
               %{name: "Relacionamento Tabu", count: 1}
             ]

      assert MapSet.new(ids(Catalog.list_visible_reel_series(user.id, show_adult: true))) ==
               MapSet.new([safe.id, explicit.id])
    end

    test "filters by display category and labels each title", %{user: user, global: global} do
      asia = category!(global, "[Reels] Histórias da Ásia")
      wolves = category!(global, "[Reels] Homem-lobo e Vampiro")
      releases = category!(global, "[Reels] Lançamentos")

      asian = reel!(global, [asia, releases], %{name: "Asian Drama"})
      wolf = reel!(global, [wolves], %{name: "Wolf Drama"})

      filtered = Catalog.list_visible_reel_series(user.id, category: "  Histórias da Ásia ")

      assert ids(filtered) == [asian.id]
      assert Enum.map(filtered, & &1.reel_category) == ["Histórias da Ásia"]

      labels =
        user.id
        |> Catalog.list_visible_reel_series()
        |> Map.new(&{&1.id, &1.reel_category})

      assert labels == %{asian.id => "Histórias da Ásia", wolf.id => "Homem-lobo e Vampiro"}

      assert Catalog.list_visible_reel_series(user.id, category: "Inexistente") == []
      assert length(Catalog.list_visible_reel_series(user.id, category: "")) == 2
    end

    test "pages newest first", %{user: user, global: global} do
      releases = category!(global, "[Reels] Lançamentos")
      oldest = global |> reel!([releases], %{name: "Oldest"}) |> backdate!(300)
      middle = global |> reel!([releases], %{name: "Middle"}) |> backdate!(200)
      newest = global |> reel!([releases], %{name: "Newest"}) |> backdate!(100)

      assert ids(Catalog.list_visible_reel_series(user.id, limit: 2)) == [newest.id, middle.id]

      assert ids(Catalog.list_visible_reel_series(user.id, limit: 2, offset: 2)) == [oldest.id]
      assert Catalog.list_visible_reel_series(user.id, limit: 2, offset: 4) == []
    end
  end

  describe "list_visible_reel_categories/2" do
    test "merges categories across providers by display name", %{user: user, global: global} do
      other = provider_fixture(user_fixture(), %{name: "Mirror", visibility: :public})

      global_asia = category!(global, "[Reels] Histórias da Ásia")
      other_asia = category!(other, "[Reels] Histórias da Ásia")
      other_dubbed = category!(other, "[Reels] Série Dublada")

      _first = reel!(global, [global_asia], %{name: "Primeiro Amor"})
      _second = reel!(other, [other_asia, other_dubbed], %{name: "Segundo Amor"})
      _shared_a = reel!(global, [global_asia], %{name: "Shared", tmdb_id: "reel-1"})
      _shared_b = reel!(other, [other_asia], %{name: "Shared 4K", tmdb_id: "reel-1"})

      assert Catalog.list_visible_reel_categories(user.id) == [
               %{name: "Histórias da Ásia", count: 3},
               %{name: "Série Dublada", count: 1}
             ]

      assert length(Catalog.list_visible_reel_series(user.id, category: "Histórias da Ásia")) ==
               3
    end
  end

  describe "public reel listings" do
    test "only use public and global providers", %{global: global} do
      owner = user_fixture()
      private = provider_fixture(owner, %{name: "Private"})
      public = provider_fixture(owner, %{name: "Public", visibility: :public})

      global_reel = reel!(global, [category!(global, "[Reels] Mais Tendência")])
      public_reel = reel!(public, [category!(public, "[Reels] Bebês e Gravidezes")])
      _private_reel = reel!(private, [category!(private, "[Reels] Mais Tendência")])

      listed = Catalog.list_public_reel_series()

      assert MapSet.new(ids(listed)) == MapSet.new([global_reel.id, public_reel.id])
      assert Enum.all?(listed, &Ecto.assoc_loaded?(&1.provider))
      assert Catalog.count_public_reel_series() == 2
      assert Catalog.count_public_reel_series(category: "Mais Tendência") == 1

      assert Catalog.list_public_reel_categories() == [
               %{name: "Bebês e Gravidezes", count: 1},
               %{name: "Mais Tendência", count: 1}
             ]
    end
  end

  defp ids(series), do: Enum.map(series, & &1.id)

  defp category!(provider, name, type \\ "series", is_adult \\ false) do
    %Category{}
    |> Category.changeset(%{
      provider_id: provider.id,
      name: name,
      type: type,
      is_adult: is_adult,
      external_id: Integer.to_string(System.unique_integer([:positive]))
    })
    |> Repo.insert!()
  end

  defp reel!(provider, categories, attrs \\ %{}) do
    series = series_content_fixture(provider, attrs)

    Repo.insert_all(
      "item_categories",
      Enum.map(categories, &%{catalog_item_id: series.catalog_item_id, category_id: &1.id})
    )

    series
  end

  defp backdate!(series, seconds_ago) do
    inserted_at =
      DateTime.utc_now()
      |> DateTime.add(-seconds_ago, :second)
      |> DateTime.truncate(:second)

    series
    |> Ecto.Changeset.change(inserted_at: inserted_at)
    |> Repo.update!()
  end
end
