defmodule StreamixWeb.Content.EpisodeDetailLiveTest do
  use StreamixWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Streamix.AccountsFixtures
  import Streamix.IptvFixtures

  alias Streamix.Iptv.{CatalogItem, Episode, Season, Series}
  alias Streamix.Iptv.Streaming.ProviderRuntime
  alias Streamix.Repo

  setup do
    ProviderRuntime.reset()
    on_exit(fn -> ProviderRuntime.reset() end)

    user = user_fixture()

    global =
      provider_fixture(user, %{
        name: "Streamix Global",
        visibility: "global",
        is_system: true,
        provider_type: "xtream",
        is_active: true
      })

    %{user: user, global: global}
  end

  test "lists equivalent episode copies with badges, health and premium lock, and navigates on selection keeping return_to",
       %{conn: conn, user: user, global: global} do
    alt_provider =
      provider_fixture(user, %{
        name: "MegaEmbed",
        visibility: "public",
        provider_type: "xtream",
        is_active: true
      })

    degraded_provider =
      provider_fixture(user, %{
        name: "GIndex Backup",
        visibility: "public",
        provider_type: "xtream",
        is_active: true
      })

    ProviderRuntime.record_failure(degraded_provider.id, :control, :timeout)

    series_a =
      create_series!(global, %{
        name: "Dawson's Creek",
        title: "Dawson's Creek",
        tmdb_id: "tmdb-dawson-100"
      })

    season_a1 = create_season!(series_a, 1)

    ep_a1 =
      create_episode!(season_a1, global, 1, %{
        name: "Dawson S01E01 1080p [DUB]",
        title: "Piloto",
        container_extension: "mp4",
        tmdb_enriched: true
      })

    ep_a2 =
      create_episode!(season_a1, global, 2, %{
        name: "Dawson S01E02 1080p [DUB]",
        title: "Dança",
        container_extension: "mp4",
        tmdb_enriched: true
      })

    series_b =
      create_series!(alt_provider, %{
        name: "Dawson's Creek [LEG]",
        title: "Dawson's Creek",
        tmdb_id: "tmdb-dawson-100"
      })

    season_b1 = create_season!(series_b, 1)

    ep_b1 =
      create_episode!(season_b1, alt_provider, 1, %{
        name: "Dawson S01E01 4K HDR DUAL",
        title: "Piloto",
        container_extension: "mkv",
        tmdb_enriched: true
      })

    _ep_b2 =
      create_episode!(season_b1, alt_provider, 2, %{
        name: "Dawson S01E02 4K HDR DUAL",
        title: "Dança",
        container_extension: "mkv",
        tmdb_enriched: true
      })

    series_c =
      create_series!(degraded_provider, %{
        name: "Dawson's Creek Backup",
        title: "Dawson's Creek",
        tmdb_id: "tmdb-dawson-100"
      })

    season_c1 = create_season!(series_c, 1)

    ep_c1 =
      create_episode!(season_c1, degraded_provider, 1, %{
        name: "Dawson S01E01 720p [LEG]",
        title: "Piloto",
        container_extension: "mp4",
        tmdb_enriched: true
      })

    conn = log_in_user(conn, user)
    return_to = "/browse/series/#{series_a.id}?source=#{series_a.id}"

    {:ok, view, _html} =
      live(
        conn,
        "/browse/series/#{series_a.id}/episode/#{ep_a1.id}?return_to=#{URI.encode_www_form(return_to)}"
      )

    # Picker is rendered with all 3 equivalent copies of S01E01
    assert has_element?(view, "#episode-source-picker[role='radiogroup']")

    assert has_element?(
             view,
             "#source-option-#{ep_a1.id}[aria-checked='true']",
             "Streamix Global"
           )

    assert has_element?(view, "#source-option-#{ep_a1.id}", "MP4")
    assert has_element?(view, "#source-option-#{ep_a1.id}", "1080p")
    assert has_element?(view, "#source-option-#{ep_a1.id}", "DUB")
    assert has_element?(view, "#source-option-#{ep_a1.id}", "Premium")

    assert has_element?(view, "#source-option-#{ep_b1.id}[aria-checked='false']", "MegaEmbed")
    assert has_element?(view, "#source-option-#{ep_b1.id}", "MKV")
    assert has_element?(view, "#source-option-#{ep_b1.id}", "4K")
    assert has_element?(view, "#source-option-#{ep_b1.id}", "HDR")
    assert has_element?(view, "#source-option-#{ep_b1.id}", "DUAL")

    assert has_element?(view, "#source-option-#{ep_c1.id}[aria-checked='false']", "GIndex Backup")
    assert has_element?(view, "#source-option-#{ep_c1.id}", "Instável")

    # "Todos os Episódios" points to /browse/series/<episode.series_id>?source=<episode.series_id>
    expected_series_path = "/browse/series/#{series_a.id}?source=#{series_a.id}"
    assert has_element?(view, ~s(#episode-all-episodes-link[href="#{expected_series_path}"]))

    # Next episode stays in the same copy (series_a / ep_a2)
    expected_next_path =
      "/browse/series/#{series_a.id}/episode/#{ep_a2.id}?return_to=#{URI.encode_www_form(return_to)}"

    assert has_element?(view, ~s(#episode-next-link[href="#{expected_next_path}"]))

    # Selecting MegaEmbed copy navigates to /browse/series/<copy.series_id>/episode/<copy.id> keeping return_to
    view
    |> element("#source-option-#{ep_b1.id}")
    |> render_click()

    expected_target =
      "/browse/series/#{series_b.id}/episode/#{ep_b1.id}?return_to=#{URI.encode_www_form(return_to)}"

    assert_redirect(view, expected_target)
  end

  test "renders a single informational line and no radiogroup when only one copy exists", %{
    conn: conn,
    user: user,
    global: global
  } do
    series =
      create_series!(global, %{
        name: "Unique Show",
        title: "Unique Show",
        tmdb_id: "tmdb-unique-999"
      })

    season = create_season!(series, 1)

    ep1 =
      create_episode!(season, global, 1, %{
        name: "Unique S01E01 1080p [LEG]",
        title: "Começo",
        container_extension: "mkv",
        tmdb_enriched: true
      })

    ep2 =
      create_episode!(season, global, 2, %{
        name: "Unique S01E02 1080p [LEG]",
        title: "Meio",
        container_extension: "mkv",
        tmdb_enriched: true
      })

    conn = log_in_user(conn, user)
    {:ok, view, _html} = live(conn, ~p"/browse/series/#{series.id}/episode/#{ep2.id}")

    refute has_element?(view, "#episode-source-picker")
    assert has_element?(view, "#episode-source-picker-info", "Fonte: Streamix Global")
    assert has_element?(view, "#episode-source-picker-info", "MKV")
    assert has_element?(view, "#episode-source-picker-info", "1080p")
    assert has_element?(view, "#episode-source-picker-info", "LEG")

    # Previous episode and Todos os Episódios stay in the same copy
    assert has_element?(
             view,
             ~s(#episode-prev-link[href="/browse/series/#{series.id}/episode/#{ep1.id}"])
           )

    assert has_element?(
             view,
             ~s(#episode-all-episodes-link[href="/browse/series/#{series.id}?source=#{series.id}"])
           )
  end

  defp create_series!(provider, attrs) do
    catalog_item =
      %CatalogItem{}
      |> CatalogItem.changeset(%{content_type: "series", provider_id: provider.id})
      |> Repo.insert!()

    params =
      Map.merge(
        %{
          series_id: System.unique_integer([:positive]),
          name: "Series #{System.unique_integer([:positive])}",
          title: "Series Title",
          year: 2024,
          provider_id: provider.id,
          tmdb_id: "tmdb-#{System.unique_integer([:positive])}",
          catalog_item_id: catalog_item.id
        },
        attrs
      )

    %Series{}
    |> Series.changeset(params)
    |> Repo.insert!()
  end

  defp create_season!(series, season_number) do
    %Season{}
    |> Season.changeset(%{
      season_number: season_number,
      name: "Temporada #{season_number}",
      series_id: series.id
    })
    |> Repo.insert!()
  end

  defp create_episode!(season, provider, episode_num, attrs) do
    catalog_item =
      %CatalogItem{}
      |> CatalogItem.changeset(%{content_type: "episode", provider_id: provider.id})
      |> Repo.insert!()

    params =
      Map.merge(
        %{
          episode_id: System.unique_integer([:positive]),
          episode_num: episode_num,
          title: "Episode #{episode_num}",
          name: "Episode #{episode_num}",
          season_id: season.id,
          catalog_item_id: catalog_item.id,
          tmdb_enriched: true
        },
        attrs
      )

    %Episode{}
    |> Episode.changeset(params)
    |> Repo.insert!()
  end
end
