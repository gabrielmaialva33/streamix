defmodule Streamix.Gindex.ClientTest do
  use ExUnit.Case, async: false

  alias Streamix.Gindex.{Client, HealthTracker}

  @legacy_stream "https://1.animezeydl.workers.dev"
  @unified_stream "https://animezey16082023.animezey16082023.workers.dev"
  @tracked_endpoints [
    {:legacy, @legacy_stream, 1},
    {:unified, @unified_stream, 2}
  ]

  setup {Req.Test, :verify_on_exit!}

  setup do
    original = Application.get_env(:streamix, :gindex_provider)

    Application.put_env(:streamix, :gindex_provider,
      enabled: true,
      stream_url: @legacy_stream
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
