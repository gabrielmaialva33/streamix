defmodule StreamixWeb.Api.V1.GamesTest do
  use StreamixWeb.ConnCase, async: false
  import OpenApiSpex.TestAssertions, only: [assert_operation_response: 2]
  import Streamix.IptvFixtures
  import Streamix.GamesFixtures
  import Streamix.AccountsFixtures

  setup do
    keys = Application.get_env(:streamix, :api_keys)
    Application.put_env(:streamix, :api_keys, ["games-test"])
    on_exit(fn -> Application.put_env(:streamix, :api_keys, keys) end)
    :ok
  end

  test "API returns a bare array of public mapped games with proxied logos and an accurate schema",
       %{conn: conn} do
    provider = global_provider_fixture(%{games_enabled: true})
    channel = channel_fixture(provider)
    game = game_fixture(provider, channel)
    game_fixture(provider, nil)

    private =
      provider_fixture(user_fixture())
      |> Ecto.Changeset.change(games_enabled: true)
      |> Streamix.Repo.update!()

    game_fixture(private, channel_fixture(private))
    conn = conn |> put_req_header("x-api-key", "games-test") |> get(~p"/api/v1/catalog/games")
    assert_operation_response(conn, "catalog.games.list")
    assert [card] = json_response(conn, 200)
    assert card["id"] == game.id and card["channel_id"] == channel.id
    assert card["live"] == true
    assert card["home"]["logo_url"] =~ "/proxy?url=https%3A%2F%2Fimages.example.com"

    assert Enum.sort(Map.keys(card)) ==
             Enum.sort(~w(id league title home away starts_at ends_at live channel_id))

    refute conn.resp_body =~ provider.password
    refute conn.resp_body =~ "/live/"
  end

  test "uses the catalog API key boundary", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/catalog/games")
    assert conn.status == 401
    assert_operation_response(conn, "catalog.games.list")
  end
end
