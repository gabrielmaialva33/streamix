defmodule StreamixWeb.StationsLiveTest do
  use StreamixWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Streamix.IptvFixtures, only: [provider_fixture: 2, channel_fixture: 2]

  alias Streamix.Iptv.Category
  alias Streamix.Programming.Station
  alias Streamix.Repo
  alias StreamixWeb.{Presence, StationPaths}

  setup :register_and_log_in_user

  setup do
    station =
      %Station{}
      |> Station.changeset(%{
        slug: "terror-anos-80",
        name: "Terror Anos 80",
        query: "terror anos 80",
        description: "Slashers."
      })
      |> Repo.insert!()
      |> Station.program_changeset(
        [
          %{
            "movie_id" => 11,
            "duration" => 3_600,
            "title" => "Pânico na Floresta",
            "year" => 1983
          },
          %{"movie_id" => 12, "duration" => 3_600, "title" => "A Noite do Terror", "year" => 0}
        ],
        DateTime.add(DateTime.utc_now(), -900, :second)
      )
      |> Repo.update!()

    %{station: station}
  end

  test "lists the numbered stations and features one with its times and what follows",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/stations")

    assert has_element?(view, "#movie_stations-terror-anos-80", "01")
    assert has_element?(view, "#movie_stations-terror-anos-80", "Terror Anos 80")
    assert has_element?(view, "#movie_stations-terror-anos-80", "Pânico na Floresta (1983)")
    assert has_element?(view, "#movie_stations-terror-anos-80 [style='width: 25%']")
    assert has_element?(view, "#movie_stations-terror-anos-80[data-selected='true']")

    assert has_element?(view, "#station-feature-title", "Pânico na Floresta (1983)")
    assert has_element?(view, "#station-feature", "A seguir A Noite do Terror")
    assert has_element?(view, "#station-feature", ~r/\d{2}:\d{2}/)
    assert has_element?(view, "#station-feature-watch[href='/stations/terror-anos-80']")
    refute has_element?(view, "#stations-empty")
  end

  test "updates the card when the station moves on and counts viewers", %{
    conn: conn,
    station: station
  } do
    {:ok, view, _html} = live(conn, ~p"/stations")

    station
    |> Station.program_changeset(
      [%{"movie_id" => 13, "duration" => 3_600, "title" => "Novo", "year" => 0}],
      DateTime.utc_now()
    )
    |> Repo.update!()

    send(view.pid, {:station_slot, "terror-anos-80", nil})
    assert has_element?(view, "#movie_stations-terror-anos-80", "Novo")
    refute render(view) =~ "(0)"

    topic = StationPaths.viewers_topic("terror-anos-80")
    :ok = Phoenix.PubSub.subscribe(Streamix.PubSub, topic)
    {:ok, _} = Presence.track(self(), topic, "42", %{})

    # The page hears the same diff; once this viewer's join reached us it
    # reached the view. (A leave left over from an earlier test may come first.)
    assert_receive %Phoenix.Socket.Broadcast{
                     event: "presence_diff",
                     payload: %{joins: %{"42" => _}}
                   },
                   5_000

    assert render(view) =~ "1 assistindo"
  end

  test "series stations get their own grid and name the episode", %{conn: conn} do
    %Station{}
    |> Station.changeset(%{
      slug: "chaves",
      name: "Chaves 24h",
      query: "Chaves 24h",
      kind: "series",
      series_tmdb_ids: ["47"]
    })
    |> Repo.insert!()
    |> Station.program_changeset(
      [
        %{
          "type" => "episode",
          "content_id" => 7,
          "duration" => 1_500,
          "title" => "Chaves",
          "subtitle" => "T1:E4 · O Barril"
        },
        %{
          "type" => "episode",
          "content_id" => 8,
          "duration" => 1_500,
          "title" => "Chaves",
          "subtitle" => "T2:E1 · A Vila"
        }
      ],
      DateTime.utc_now()
    )
    |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/stations")

    assert has_element?(
             view,
             "#series-stations #series_stations-chaves",
             "Chaves · T1:E4 · O Barril"
           )

    assert has_element?(view, "#movie-stations #movie_stations-terror-anos-80")

    # Picking a channel previews it in the feature, title and episode apart.
    view |> element("#series_stations-chaves button[phx-click='select']") |> render_click()
    assert has_element?(view, "#series_stations-chaves[data-selected='true']")
    assert has_element?(view, "#movie_stations-terror-anos-80[data-selected='false']")
    assert has_element?(view, "#station-feature-title", "Chaves")
    assert has_element?(view, "#station-feature", "T1:E4 · O Barril")
    assert has_element?(view, "#station-feature", "A seguir Chaves · T2:E1 · A Vila")

    assert {:error, {:redirect, %{to: "/watch/episode/7?station=chaves&t=" <> _}}} =
             live(conn, ~p"/stations/chaves")
  end

  test "tuning in jumps to the film on air at the current minute", %{conn: conn} do
    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/stations/terror-anos-80")
    assert to =~ ~r{^/watch/movie/11\?station=terror-anos-80&t=(89[5-9]|90[0-9])$}
  end

  test "an off-air station sends the viewer back to the list", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/stations", flash: flash}}} =
             live(conn, ~p"/stations/sumiu")

    assert flash["error"] =~ "fora do ar"
  end

  test "no stations, a plain empty state", %{conn: conn, station: station} do
    Repo.delete!(station)
    {:ok, view, _html} = live(conn, ~p"/stations")
    assert has_element?(view, "#stations-empty")
  end

  test "lists the providers' 24h channels by kind, adult ones left out", %{conn: conn, user: user} do
    provider =
      provider_fixture(user, %{
        visibility: "global",
        is_system: true,
        provider_type: "xtream",
        is_active: true
      })

    series = category!(provider, "24H | Séries")
    cartoons = category!(provider, "24HRS I DESENHOS")
    adult = category!(provider, "24HRS I ADULTOS", is_adult: true)
    regular = category!(provider, "Esportes")

    chaves = channel!(provider, "Chaves", series)
    channel!(provider, "Chaves", series)
    pink = channel!(provider, "A Pantera Cor de Rosa", cartoons)
    hidden = channel!(provider, "Proibido", adult)
    sports = channel!(provider, "Esporte 1", regular)

    {:ok, view, _html} = live(conn, ~p"/stations")

    assert has_element?(view, "#list-tab-series", "Séries")
    assert has_element?(view, "#list-tab-desenhos", "Desenhos")

    # One channel each after the duplicate "Chaves" collapses: a tie, so the
    # first tab is alphabetical.
    assert has_element?(view, "#list-tab-desenhos[aria-selected='true']")
    view |> element("#list-tab-series") |> render_click()

    assert has_element?(
             view,
             "#list-channel-grid a[href='/watch/live_channel/#{chaves.id}']",
             "Chaves"
           )

    # The duplicate "Chaves" is listed once.
    assert view
           |> element("#list-channel-grid")
           |> render()
           |> String.split("/watch/live_channel/")
           |> length() == 2

    view |> element("#list-tab-desenhos") |> render_click()
    assert has_element?(view, "#list-channel-grid a[href='/watch/live_channel/#{pink.id}']")
    refute has_element?(view, "#list-channel-grid a[href='/watch/live_channel/#{chaves.id}']")

    html = render(view)
    refute html =~ "/watch/live_channel/#{hidden.id}"
    refute html =~ "/watch/live_channel/#{sports.id}"
  end

  test "a long 24h list shows a page and loads the rest on demand", %{conn: conn, user: user} do
    provider =
      provider_fixture(user, %{
        visibility: "global",
        is_system: true,
        provider_type: "xtream",
        is_active: true
      })

    cartoons = category!(provider, "24HRS I DESENHOS")

    channels =
      for n <- 1..30,
          do:
            channel!(
              provider,
              "Desenho #{String.pad_leading(Integer.to_string(n), 2, "0")}",
              cartoons
            )

    {:ok, view, _html} = live(conn, ~p"/stations")

    grid = fn -> view |> element("#list-channel-grid") |> render() end
    assert grid.() |> String.split("/watch/live_channel/") |> length() == 25
    assert has_element?(view, "#list-more", "(6)")
    refute has_element?(view, "a[href='/watch/live_channel/#{List.last(channels).id}']")

    view |> element("#list-more") |> render_click()
    assert has_element?(view, "a[href='/watch/live_channel/#{List.last(channels).id}']")
    assert grid.() |> String.split("/watch/live_channel/") |> length() == 31
    refute has_element?(view, "#list-more")
  end

  defp category!(provider, name, opts \\ []) do
    %Category{}
    |> Category.changeset(%{
      provider_id: provider.id,
      name: name,
      type: "live",
      is_adult: Keyword.get(opts, :is_adult, false),
      external_id: Integer.to_string(System.unique_integer([:positive]))
    })
    |> Repo.insert!()
  end

  defp channel!(provider, name, category) do
    channel =
      channel_fixture(provider, %{
        name: name,
        stream_icon: "https://img.test/#{name}.png"
      })

    Repo.insert_all("item_categories", [
      %{catalog_item_id: channel.catalog_item_id, category_id: category.id}
    ])

    channel
  end
end
