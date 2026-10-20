defmodule StreamixWeb.Content.ReelsLiveTest do
  use StreamixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv.Category
  alias Streamix.Repo

  setup %{conn: conn} do
    user = user_fixture()
    global = global_provider_fixture(%{name: "MegaEmbed"})

    %{conn: log_in_user(conn, user), user: user, global: global}
  end

  test "renders reel cards, category chips and the active nav tab", %{conn: conn, global: global} do
    asia = category!(global, "[Reels] Histórias da Ásia")
    wolves = category!(global, "[Reels] Homem-lobo e Vampiro")
    asian = reel!(global, [asia], %{name: "Amor em Seul"})
    wolf = reel!(global, [wolves], %{name: "Lua de Sangue"})
    regular = series_content_fixture(global, %{name: "Regular Show"})

    {:ok, view, _html} = live(conn, ~p"/browse/reels")

    assert page_title(view) =~ "Dramas curtos"
    assert has_element?(view, "#browse-tab-reels.content-nav__tab--active", "Dramas curtos")
    assert has_element?(view, "#reel-category-all.category-chip--active", "Todas")
    assert has_element?(view, chip("Histórias da Ásia"), "Histórias da Ásia")
    assert has_element?(view, chip("Homem-lobo e Vampiro"), "Homem-lobo e Vampiro")

    assert has_element?(view, "#reels-grid #series-card-#{asian.id}")
    assert has_element?(view, "#reels-grid #series-card-#{wolf.id}")
    refute has_element?(view, "#series-card-#{regular.id}")
  end

  test "category chips patch the URL and filter the grid", %{conn: conn, global: global} do
    asia = category!(global, "[Reels] Histórias da Ásia")
    wolves = category!(global, "[Reels] Homem-lobo e Vampiro")
    asian = reel!(global, [asia], %{name: "Amor em Seul"})
    wolf = reel!(global, [wolves], %{name: "Lua de Sangue"})

    {:ok, view, _html} = live(conn, ~p"/browse/reels")

    view |> element(chip("Histórias da Ásia")) |> render_click()

    assert_patch(view, ~p"/browse/reels?#{%{category: "Histórias da Ásia"}}")
    assert has_element?(view, chip("Histórias da Ásia") <> ".category-chip--active")
    refute has_element?(view, "#reel-category-all.category-chip--active")
    assert has_element?(view, "#series-card-#{asian.id}")
    refute has_element?(view, "#series-card-#{wolf.id}")

    view |> element("#reel-category-all") |> render_click()

    assert_patch(view, ~p"/browse/reels")
    assert has_element?(view, "#series-card-#{asian.id}")
    assert has_element?(view, "#series-card-#{wolf.id}")
  end

  test "merges same-named categories from every visible provider", %{
    conn: conn,
    user: user,
    global: global
  } do
    own = provider_fixture(user, %{name: "Own"})
    global_reel = reel!(global, [category!(global, "[Reels] Série Dublada")])
    own_reel = reel!(own, [category!(own, "[Reels] Série Dublada")])

    {:ok, view, _html} = live(conn, ~p"/browse/reels?#{%{category: "Série Dublada"}}")

    assert has_element?(view, chip("Série Dublada") <> ".category-chip--active", "2")
    assert has_element?(view, "#series-card-#{global_reel.id}")
    assert has_element?(view, "#series-card-#{own_reel.id}")
  end

  test "opens the series detail page with a return path", %{conn: conn, global: global} do
    drama = reel!(global, [category!(global, "[Reels] Lançamentos")])

    {:ok, view, _html} = live(conn, ~p"/browse/reels?#{%{category: "Lançamentos"}}")

    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> element("#series-card-#{drama.id} [data-media-primary]")
             |> render_click()

    assert %URI{path: path, query: query} = URI.parse(to)
    assert path == "/browse/series/#{drama.id}"
    assert URI.decode_query(query) == %{"return_to" => "/browse/reels?category=Lan%C3%A7amentos"}
  end

  test "toggles favorites from the card and handles hover-preview events", %{
    conn: conn,
    global: global
  } do
    drama = reel!(global, [category!(global, "[Reels] Lançamentos")])

    {:ok, view, _html} = live(conn, ~p"/browse/reels")

    view
    |> element(~s(#series-card-#{drama.id} button[aria-label="Adicionar aos favoritos"]))
    |> render_click()

    assert has_element?(
             view,
             ~s(#series-card-#{drama.id} button[aria-label="Remover dos favoritos"])
           )

    assert {:error, {:live_redirect, %{to: "/browse/series/" <> _rest}}} =
             render_hook(view, "show_details", %{"id" => drama.id})
  end

  test "badges only plan-gated titles for users without premium access", %{
    conn: conn,
    user: user,
    global: global
  } do
    own = provider_fixture(user, %{name: "Own"})
    global_reel = reel!(global, [category!(global, "[Reels] Mais Tendência")])
    own_reel = reel!(own, [category!(own, "[Reels] Mais Tendência")])

    {:ok, view, _html} = live(conn, ~p"/browse/reels")

    assert has_element?(view, "#reels-premium-cta")
    assert has_element?(view, "#series-card-#{global_reel.id} [data-premium-badge]")
    refute has_element?(view, "#series-card-#{own_reel.id} [data-premium-badge]")
  end

  test "loads further pages on demand", %{conn: conn, global: global} do
    releases = category!(global, "[Reels] Lançamentos")
    reels = for index <- 1..49, do: reel!(global, [releases], %{name: "Drama #{index}"})

    {:ok, view, _html} = live(conn, ~p"/browse/reels")

    assert view |> element("#reels-grid") |> render() |> count_cards() == 48
    assert has_element?(view, "#reels-sentinel")

    assert render_hook(view, "load_more", %{}) =~ "series-card-"
    assert view |> element("#reels-grid") |> render() |> count_cards() == length(reels)
    refute has_element?(view, "#reels-sentinel")
  end

  test "shows an empty state with a reset link for an unknown category", %{
    conn: conn,
    global: global
  } do
    reel!(global, [category!(global, "[Reels] Lançamentos")])

    {:ok, view, html} = live(conn, ~p"/browse/reels?#{%{category: "Inexistente"}}")

    assert html =~ "Nenhum drama curto encontrado"
    assert has_element?(view, "#reels-empty-reset")
    refute has_element?(view, "#reels-sentinel")
  end

  test "the series browse tabs link to the reels page", %{conn: conn, global: global} do
    series_content_fixture(global, %{name: "Any Show"})

    {:ok, view, _html} = live(conn, ~p"/browse/series")

    assert has_element?(view, ~s(#browse-tab-reels[href="/browse/reels"]), "Dramas curtos")
    refute has_element?(view, "#browse-tab-reels.content-nav__tab--active")
  end

  test "chips keep distinct ids and full names, however the names look", %{
    conn: conn,
    global: global
  } do
    long_name = String.duplicate("Romance proibido ", 7) |> String.trim()
    names = ["All", "Ação", "Acao", "爱情", "家庭", long_name]

    reels =
      for name <- names,
          into: %{},
          do: {name, reel!(global, [category!(global, "[Reels] " <> name)])}

    {:ok, view, html} = live(conn, ~p"/browse/reels")

    ids =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#reel-categories a")
      |> LazyHTML.attribute("id")

    assert length(ids) == length(names) + 1
    assert ids == Enum.uniq(ids)

    # A name longer than 100 characters still round-trips through the filter.
    assert String.length(long_name) > 100
    view |> element(chip(long_name)) |> render_click()
    assert_patch(view, ~p"/browse/reels?#{%{category: long_name}}")
    assert has_element?(view, chip(long_name) <> ".category-chip--active")
    assert has_element?(view, "#series-card-#{reels[long_name].id}")
    refute has_element?(view, "#series-card-#{reels["Ação"].id}")
  end

  test "search input filters reel series by title", %{conn: conn, global: global} do
    cat = category!(global, "[Reels] Romance")
    match = reel!(global, [cat], %{name: "Casamento Secreto", title: "Casamento Secreto"})
    other = reel!(global, [cat], %{name: "Vingança da Herdeira", title: "Vingança da Herdeira"})

    {:ok, view, _html} = live(conn, ~p"/browse/reels")

    assert has_element?(view, "#reels-search-form input[name='search']")

    view
    |> form("#reels-search-form", %{search: "Casamento"})
    |> render_submit()

    assert_patch(view, ~p"/browse/reels?search=Casamento")
    assert has_element?(view, "#series-card-#{match.id}")
    refute has_element?(view, "#series-card-#{other.id}")
  end

  test "a category keeps the active search, and Todas drops only the category", %{
    conn: conn,
    global: global
  } do
    romance = category!(global, "[Reels] Romance")
    match = reel!(global, [romance], %{name: "Casamento Secreto", title: "Casamento Secreto"})
    other = reel!(global, [romance], %{name: "Vingança da Herdeira", title: "Vingança"})

    {:ok, view, _html} = live(conn, ~p"/browse/reels?search=Casamento")

    view |> element(chip("Romance")) |> render_click()
    assert_patch(view, "/browse/reels?category=Romance&search=Casamento")
    assert has_element?(view, "#series-card-#{match.id}")
    refute has_element?(view, "#series-card-#{other.id}")

    view |> element("#reel-category-all") |> render_click()
    assert_patch(view, ~p"/browse/reels?search=Casamento")
    assert has_element?(view, "#reels-search-form input[name='search'][value='Casamento']")
  end

  defp chip(name), do: ~s(#reel-categories a[data-category="#{name}"])

  defp count_cards(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[id^='series-card-']")
    |> Enum.count()
  end

  defp category!(provider, name) do
    %Category{}
    |> Category.changeset(%{
      provider_id: provider.id,
      name: name,
      type: "series",
      external_id: Integer.to_string(System.unique_integer([:positive]))
    })
    |> Repo.insert!()
  end

  defp reel!(provider, categories, attrs \\ %{}) do
    series =
      provider
      |> series_content_fixture(attrs)
      |> Ecto.Changeset.change(cover: "https://image.tmdb.org/t/p/w500/reel.jpg")
      |> Repo.update!()

    Repo.insert_all(
      "item_categories",
      Enum.map(categories, &%{catalog_item_id: series.catalog_item_id, category_id: &1.id})
    )

    series
  end
end
