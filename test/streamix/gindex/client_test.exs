defmodule Streamix.Gindex.ClientTest do
  use ExUnit.Case, async: false

  alias Streamix.Gindex.{Client, HealthTracker}

  @legacy_sync "https://1.animezey23112022.workers.dev"
  @legacy_stream "https://1.animezeydl.workers.dev"
  @unified_stream "https://animezey16082023.animezey16082023.workers.dev"
  @tracked_endpoints [
    {:legacy_sync, @legacy_sync, 1},
    {:legacy_stream, @legacy_stream, 2},
    {:unified, @unified_stream, 3}
  ]

  setup {Req.Test, :verify_on_exit!}

  setup do
    original = Application.get_env(:streamix, :gindex_provider)

    Application.put_env(:streamix, :gindex_provider,
      enabled: true,
      sync_url: @legacy_sync,
      stream_url: @legacy_stream,
      endpoints: [@legacy_sync, @legacy_stream]
    )

    HealthTracker.reset_all(@tracked_endpoints)

    on_exit(fn ->
      HealthTracker.reset_all(@tracked_endpoints)

      if original,
        do: Application.put_env(:streamix, :gindex_provider, original),
        else: Application.delete_env(:streamix, :gindex_provider)
    end)

    :ok
  end

  test "fails over token minting to the verified unified Worker" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "1.animezeydl.workers.dev"
      Plug.Conn.send_resp(conn, 429, "error code: 1027")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "animezey16082023.animezey16082023.workers.dev"
      Plug.Conn.send_resp(conn, 200, ~s({"link":"/download.aspx?file=fresh-token"}))
    end)

    assert {:ok, url} =
             Client.get_download_url_with_failover(
               "/1:/Filmes/example.mkv",
               nil,
               plug: {Req.Test, __MODULE__},
               quota_fun: fn :playback -> {:ok, :ok, 1} end
             )

    uri = URI.parse(url)
    assert uri.host == "animezey16082023.animezey16082023.workers.dev"
    assert URI.decode_query(uri.query) == %{"file" => "fresh-token", "inline" => "true"}
  end

  test "fails over a single-page listing to the verified unified Worker" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:listing_request, conn.host})

      case conn.host do
        "animezey16082023.animezey16082023.workers.dev" ->
          Plug.Conn.send_resp(
            conn,
            200,
            ~s({"data":{"files":[{"name":"Temporada 1","mimeType":"application/vnd.google-apps.folder"}]}})
          )

        _legacy_host ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "90")
          |> Plug.Conn.send_resp(429, "error code: 1027")
      end
    end)

    path = "/0:/Desenhos/(Des)encanto [Disenchantment] (2018)/"

    assert {:ok, [folder]} =
             Client.list_folder_with_failover(
               path,
               @legacy_sync,
               plug: {Req.Test, __MODULE__},
               quota_fun: fn :background -> {:ok, :ok, 1} end
             )

    assert folder.name == "Temporada 1"
    assert folder.type == :folder
    assert folder.path == path <> "Temporada 1/"
    assert_received {:listing_request, "1.animezey23112022.workers.dev"}
    assert_received {:listing_request, "animezey16082023.animezey16082023.workers.dev"}
  end

  test "does not fan out a single-page listing when the local quota is exhausted" do
    test_pid = self()

    assert {:error, {:quota_exhausted, 8_000}} =
             Client.list_folder_with_failover(
               "/1:/Filmes/2026/",
               @legacy_sync,
               plug: {Req.Test, __MODULE__},
               quota_fun: fn :background ->
                 send(test_pid, :listing_quota_checked)
                 {:error, :exhausted, 8_000}
               end
             )

    assert_received :listing_quota_checked
    refute_receive :listing_quota_checked
  end

  test "does not fan out when the local playback quota is exhausted" do
    assert {:error, {:quota_exhausted, 8_000}} =
             Client.get_download_url_with_failover(
               "/1:/Filmes/example.mkv",
               nil,
               plug: {Req.Test, __MODULE__},
               quota_fun: fn :playback -> {:error, :exhausted, 8_000} end
             )
  end
end
