defmodule Streamix.Iptv.GamesTest do
  use Streamix.DataCase, async: false
  import Streamix.IptvFixtures
  import Streamix.GamesFixtures
  alias Streamix.Iptv
  alias Streamix.Iptv.Provider

  test "games flag is operator-only" do
    assert Ecto.Changeset.get_change(
             Provider.changeset(%Provider{}, %{games_enabled: true}),
             :games_enabled
           )

    refute Ecto.Changeset.get_change(
             Provider.user_changeset(%Provider{}, %{games_enabled: true}),
             :games_enabled
           )
  end

  test "sync maps provider-local channels, upserts and never stores player URLs" do
    provider =
      global_provider_fixture(%{
        games_enabled: true,
        send_x_domain: true,
        url: "https://93.184.216.34"
      })

    channel = channel_fixture(provider, %{stream_id: 71})
    now = ~U[2026-10-19 18:00:00Z]
    payload = game_payload(provider, 71, DateTime.add(now, -1800), DateTime.add(now, 1800))

    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-domain") != []
      assert conn.request_path == "/api/jogos/#{provider.username}/#{provider.password}"
      Req.Test.json(conn, [payload])
    end)

    assert {:ok, 1} = Iptv.sync_games(provider, http_options: [plug: {Req.Test, __MODULE__}])
    assert {:ok, 1} = Iptv.sync_games(provider, http_options: [plug: {Req.Test, __MODULE__}])
    assert [game] = Iptv.list_games(nil, now: now)
    assert game.live_channel_id == channel.id
    assert game.home_name == "Monza"
    refute inspect(game) =~ provider.password
    refute inspect(game) =~ "/live/"
  end

  test "failover and redirects scope X-Domain to registered panel hosts" do
    provider =
      global_provider_fixture(%{
        games_enabled: true,
        send_x_domain: true,
        url: "https://93.184.216.34",
        urls: ["https://104.16.1.1"]
      })

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.host do
        "93.184.216.34" ->
          assert Plug.Conn.get_req_header(conn, "x-domain") != []
          Plug.Conn.send_resp(conn, 503, "unavailable")

        "104.16.1.1" ->
          assert Plug.Conn.get_req_header(conn, "x-domain") != []

          conn
          |> Plug.Conn.put_resp_header("location", "https://104.16.2.2/games")
          |> Plug.Conn.send_resp(302, "")

        "104.16.2.2" ->
          assert Plug.Conn.get_req_header(conn, "x-domain") == []
          Req.Test.json(conn, [])
      end
    end)

    assert {:ok, 0} = Iptv.sync_games(provider, http_options: [plug: {Req.Test, __MODULE__}])
  end

  test "private-network feeds and redirects are blocked before the target is requested" do
    provider = global_provider_fixture(%{games_enabled: true, url: "http://127.0.0.1"})
    Req.Test.stub(__MODULE__, fn _conn -> flunk("private target was fetched") end)

    assert {:error, :games_unavailable} =
             Iptv.sync_games(provider, http_options: [plug: {Req.Test, __MODULE__}])

    provider = %{provider | url: "https://93.184.216.34"}

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "93.184.216.34"

      conn
      |> Plug.Conn.put_resp_header("location", "http://127.0.0.1/private")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, :games_unavailable} =
             Iptv.sync_games(provider, http_options: [plug: {Req.Test, __MODULE__}])
  end

  test "malformed or oversized responses return safe errors and preserve existing rows" do
    provider = global_provider_fixture(%{games_enabled: true, url: "https://93.184.216.34"})
    game = game_fixture(provider, nil)

    for body <- ["{bad json #{provider.password}", "null", :binary.copy("x", 1_048_577)] do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)

      assert {:error, :games_unavailable} =
               Iptv.sync_games(provider, http_options: [plug: {Req.Test, __MODULE__}])

      assert Repo.get(Streamix.Iptv.SportsMatch, game.id)
    end
  end

  test "unknown and foreign player URLs stay unmapped and sensitive logos are discarded" do
    provider = global_provider_fixture(%{games_enabled: true, url: "https://93.184.216.34"})
    channel = channel_fixture(provider, %{stream_id: 71})
    other = global_provider_fixture(%{games_enabled: true})
    channel_fixture(other, %{stream_id: 72})
    now = DateTime.utc_now(:second)
    payload = game_payload(provider, 72, now, DateTime.add(now, 3600))

    payload =
      put_in(
        payload,
        ["data", "teams", "home", "image"],
        "https://images.example.com/#{provider.password}.png"
      )

    forged = game_payload(provider, 71, DateTime.add(now, 7200), DateTime.add(now, 10_800))

    forged =
      put_in(forged, ["data", "players"], [
        "https://104.16.2.2/live/#{provider.username}/#{provider.password}/71.m3u8"
      ])

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, [payload, forged, %{}, nil, %{"data" => nil}])
    end)

    assert {:ok, 2} = Iptv.sync_games(provider, http_options: [plug: {Req.Test, __MODULE__}])
    assert Iptv.list_games(nil) == []
    rows = Repo.all(Streamix.Iptv.SportsMatch)
    assert Enum.all?(rows, &is_nil(&1.live_channel_id))
    assert Enum.any?(rows, &is_nil(&1.home_logo_url))
    refute inspect(rows) =~ provider.password
    # A later sync resolves a channel that was previously missing.
    channel_fixture(provider, %{stream_id: 72})
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, [payload]) end)
    assert {:ok, 1} = Iptv.sync_games(provider, http_options: [plug: {Req.Test, __MODULE__}])
    assert [mapped] = Iptv.list_games(nil)
    assert mapped.live_channel_id != channel.id
  end

  test "sports credential paths are redacted from diagnostic values" do
    refute Streamix.SafeLog.redact_url(
             "https://panel.example/api/jogos/secret-user/secret-password"
           ) =~ "secret"
  end

  test "long logo URLs and metadata updates keep one stable match" do
    provider = global_provider_fixture(%{games_enabled: true, url: "https://93.184.216.34"})
    channel = channel_fixture(provider)
    now = DateTime.utc_now(:second)
    payload = game_payload(provider, channel.stream_id, now, DateTime.add(now, 3600))
    long_logo = "https://images.example.com/" <> String.duplicate("a", 300) <> ".png"
    payload = put_in(payload, ["data", "teams", "home", "image"], long_logo)
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, [payload, payload]) end)
    assert {:ok, 1} = Iptv.sync_games(provider, http_options: [plug: {Req.Test, __MODULE__}])
    assert [before] = Iptv.list_games(nil)
    assert before.home_logo_url == long_logo

    payload =
      Map.put(payload, "title", "Updated match title")
      |> put_in(["data", "timer", "end"], to_string(DateTime.to_unix(DateTime.add(now, 7200))))

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, [payload]) end)
    assert {:ok, 1} = Iptv.sync_games(provider, http_options: [plug: {Req.Test, __MODULE__}])
    assert [updated] = Iptv.list_games(nil)
    assert updated.id == before.id
    assert updated.title == "Updated match title"
    assert updated.ends_at == DateTime.add(now, 7200)
  end
end
