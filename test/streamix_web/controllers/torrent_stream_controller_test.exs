defmodule StreamixWeb.TorrentStreamControllerTest do
  use StreamixWeb.ConnCase, async: false

  alias Streamix.Iptv.TorrentProvider
  alias Streamix.Repo
  alias Streamix.Torrent.TorrentStream

  @magnet "magnet:?xt=urn:btih:#{String.duplicate("a", 40)}"

  setup_all do
    prior = Application.get_env(:streamix, :torrent_provider)

    Application.put_env(:streamix, :torrent_provider,
      enabled: true,
      rqbit_url: "http://127.0.0.1:65535"
    )

    on_exit(fn ->
      if prior, do: Application.put_env(:streamix, :torrent_provider, prior)
    end)

    :ok
  end

  describe "GET /api/stream/torrent/:info_hash/:file_idx" do
    test "redirects anonymous users to login", %{conn: conn} do
      hash = String.duplicate("a", 40)

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> get("/api/stream/torrent/#{hash}/0")

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/login"]
    end

    test "returns 404 when info_hash has no row", %{conn: conn} do
      :ok = setup_torrent_session_supervisors()
      conn = log_in_test_user(conn)

      hash = String.duplicate("b", 40)
      conn = get(conn, "/api/stream/torrent/#{hash}/0")
      assert conn.status == 404
    end

    test "returns 403 when the torrent provider row is missing", %{conn: conn} do
      conn = log_in_test_user(conn)
      ts = insert_torrent_stream!()

      conn = get(conn, "/api/stream/torrent/#{ts.info_hash}/status")
      assert conn.status == 403
    end

    @tag :integration
    test "returns 504 when rqbit never reaches `live`", %{conn: conn} do
      # Live integration test — relies on a real (or stubbed) rqbit on
      # the configured URL. Not run by default.
      :ok = setup_torrent_session_supervisors()
      {:ok, _provider} = TorrentProvider.ensure_exists!()
      conn = log_in_test_user(conn)

      ts = insert_torrent_stream!()

      conn = get(conn, "/api/stream/torrent/#{ts.info_hash}/0")
      assert conn.status == 504
    end
  end

  describe "GET /api/stream/torrent/:info_hash/status" do
    test "redirects anonymous users to login", %{conn: conn} do
      hash = String.duplicate("a", 40)

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> get("/api/stream/torrent/#{hash}/status")

      assert conn.status == 302
    end

    test "returns 404 for unknown info_hash", %{conn: conn} do
      conn = log_in_test_user(conn)
      hash = String.duplicate("c", 40)

      conn = get(conn, "/api/stream/torrent/#{hash}/status")
      assert conn.status == 404
    end

    test "accepts JSON requests from the swarm gate", %{conn: conn} do
      hash = String.duplicate("d", 40)

      conn =
        conn
        |> log_in_test_user()
        |> put_req_header("accept", "application/json")
        |> get("/api/stream/torrent/#{hash}/status")

      assert conn.status == 404
      refute conn.status == 406
    end
  end

  # ---- helpers ----

  defp insert_torrent_stream! do
    # Need at least a movie row for the FK. Reuse the global provider
    # fixture so we don't need to seed the torrent provider itself.
    provider = Streamix.IptvFixtures.global_provider_fixture()
    movie = Streamix.IptvFixtures.movie_fixture(provider)

    %TorrentStream{}
    |> TorrentStream.changeset(%{
      info_hash: String.duplicate("a", 40),
      magnet_uri: @magnet,
      source_slug: "yts",
      movie_id: movie.id
    })
    |> Repo.insert!()
  end

  defp log_in_test_user(conn) do
    user = Streamix.AccountsFixtures.user_fixture()
    log_in_user(conn, user)
  end

  defp setup_torrent_session_supervisors do
    # Ensure the supervisors required by start_or_join exist for the
    # integration test path. Tests not exercising this don't need them.
    case Process.whereis(Streamix.Torrent.StreamRegistry) do
      nil ->
        start_supervised!({Registry, keys: :unique, name: Streamix.Torrent.StreamRegistry})

      _ ->
        :ok
    end

    case Process.whereis(Streamix.Torrent.StreamSessionSupervisor) do
      nil ->
        start_supervised!(
          {DynamicSupervisor,
           name: Streamix.Torrent.StreamSessionSupervisor, strategy: :one_for_one}
        )

      _ ->
        :ok
    end

    :ok
  end
end
