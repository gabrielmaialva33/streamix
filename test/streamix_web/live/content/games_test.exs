defmodule StreamixWeb.Content.GamesTest do
  use StreamixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Streamix.IptvFixtures
  import Streamix.AccountsFixtures
  import Streamix.GamesFixtures

  test "rail streams visible matches with safe logos, live badge and player links", %{conn: conn} do
    user = user_fixture()
    provider = global_provider_fixture(%{games_enabled: true})
    channel = channel_fixture(provider)
    game = game_fixture(provider, channel)

    private =
      provider_fixture(user)
      |> Ecto.Changeset.change(games_enabled: true)
      |> Streamix.Repo.update!()

    own_game = game_fixture(private, channel_fixture(private))

    stranger =
      provider_fixture(user_fixture())
      |> Ecto.Changeset.change(games_enabled: true)
      |> Streamix.Repo.update!()

    hidden = game_fixture(stranger, channel_fixture(stranger))
    {:ok, view, html} = conn |> log_in_user(user) |> live(~p"/browse")
    assert has_element?(view, "#games-today-list[phx-update=stream]")
    # The player lives in another live_session, so the card is a plain
    # link, like the channel cards, rather than a LiveView navigation.
    assert has_element?(view, "#games-#{game.id} a[href='/watch/live_channel/#{channel.id}']")
    refute has_element?(view, "#games-#{game.id} a[data-phx-link]")
    assert has_element?(view, "#games-#{game.id} [data-live=true]", "AO VIVO")
    assert has_element?(view, "#games-#{game.id} img[src*='/proxy?url=']")
    assert has_element?(view, "#games-#{own_game.id}")
    refute has_element?(view, "#games-#{hidden.id}")
    refute html =~ provider.password
    provider |> Ecto.Changeset.change(games_enabled: false) |> Streamix.Repo.update!()
    send(view.pid, :refresh_games)
    refute has_element?(view, "#games-#{game.id}")
  end

  test "empty rail is hidden", %{conn: conn} do
    {:ok, view, _} = conn |> log_in_user(user_fixture()) |> live(~p"/browse")
    refute has_element?(view, "#games-today")
  end
end
