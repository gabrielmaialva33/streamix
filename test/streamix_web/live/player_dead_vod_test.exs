defmodule StreamixWeb.PlayerDeadVodTest do
  use StreamixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Streamix.IptvFixtures
  alias Streamix.Iptv.{Episode, Season}

  setup :register_and_log_in_user

  test "a dead movie starts on an authorized equivalent provider without loading the dead URL", %{
    conn: conn,
    user: user
  } do
    first = provider_fixture(user)
    second = provider_fixture(user)
    dead = movie_fixture(first, %{tmdb_id: "50100"}) |> mark_dead()
    alive = movie_fixture(second, %{tmdb_id: "50100"})
    {:ok, view, html} = live(conn, ~p"/watch/movie/#{dead.id}")
    assert has_element?(view, "#video-player-container[data-content-id='#{alive.id}']")

    assert html
           |> LazyHTML.from_document()
           |> LazyHTML.query("#video-player-container")
           |> LazyHTML.attribute("data-content-id") == [to_string(alive.id)]
  end

  test "a dead movie without an accessible alternate immediately returns a friendly error", %{
    conn: conn,
    user: user
  } do
    provider = provider_fixture(user)
    dead = movie_fixture(provider, %{tmdb_id: "50101"}) |> mark_dead()
    other_user = Streamix.AccountsFixtures.user_fixture()
    hidden = provider_fixture(other_user)
    movie_fixture(hidden, %{tmdb_id: "50101"})

    assert {:error, {:redirect, %{to: "/", flash: %{"error" => message}}}} =
             live(conn, ~p"/watch/movie/#{dead.id}")

    assert message =~ "indisponível"
  end

  test "a dead episode switches to the same season and episode of another provider", %{
    conn: conn,
    user: user
  } do
    first = provider_fixture(user)
    second = provider_fixture(user)
    series_a = series_content_fixture(first, %{tmdb_id: "50102"})
    series_b = series_content_fixture(second, %{tmdb_id: "50102"})
    dead = episode(series_a, first) |> mark_dead()
    alive = episode(series_b, second)
    {:ok, view, _html} = live(conn, ~p"/watch/episode/#{dead.id}")
    assert has_element?(view, "#video-player-container[data-content-id='#{alive.id}']")
  end

  test "a channel that answered 404 shows it is off the air instead of retrying", %{
    conn: conn,
    user: user
  } do
    channel = provider_fixture(user) |> channel_fixture() |> mark_dead()

    assert {:error, {:redirect, %{to: "/", flash: %{"error" => message}}}} =
             live(conn, ~p"/watch/live_channel/#{channel.id}")

    assert message =~ "fora do ar"
  end

  test "a channel past its 24-hour recheck window is tried again", %{conn: conn, user: user} do
    channel =
      provider_fixture(user)
      |> channel_fixture()
      |> Ecto.Changeset.change(dead_since: DateTime.add(DateTime.utc_now(:second), -25 * 3600))
      |> Streamix.Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/watch/live_channel/#{channel.id}")
    assert has_element?(view, "#video-player-container")
  end

  defp mark_dead(content) do
    content
    |> Ecto.Changeset.change(dead_since: DateTime.utc_now(:second))
    |> Streamix.Repo.update!()
  end

  defp episode(series, provider) do
    season = Streamix.Repo.insert!(%Season{series_id: series.id, season_number: 1})
    ci = catalog_item_fixture("episode", provider.id)

    Streamix.Repo.insert!(%Episode{
      season_id: season.id,
      catalog_item_id: ci.id,
      episode_id: System.unique_integer([:positive]),
      episode_num: 1,
      title: "Test episode",
      container_extension: "mp4"
    })
  end
end
