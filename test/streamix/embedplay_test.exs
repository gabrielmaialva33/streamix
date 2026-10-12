defmodule Streamix.EmbedplayTest do
  use Streamix.DataCase, async: false

  alias Streamix.{Catalog, Embedplay, Providers}
  alias Streamix.Embedplay.{Health, HealthWindow}

  setup do
    original = Application.get_env(:streamix, :embedplay, [])

    Application.put_env(:streamix, :embedplay,
      enabled: true,
      resolver_url: "http://127.0.0.1:9999",
      resolver_token: "test-only",
      http_options: [plug: {Req.Test, __MODULE__}]
    )

    # Resolutions run in tasks owned by the shared session process.
    Req.Test.set_req_test_to_shared()
    # The application's window is shared by every test that opens a movie;
    # start clean and leave it clean.
    reset_window = fn -> :sys.replace_state(Health, fn _window -> HealthWindow.new() end) end
    reset_window.()
    on_exit(reset_window)

    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:resolver_called, conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(502, ~s({"error":{"code":"stream_unavailable"}}))
    end)

    on_exit(fn -> Application.put_env(:streamix, :embedplay, original) end)
    :ok
  end

  defp import_movies(count) do
    for _ <- 1..count do
      {:ok, id} = Embedplay.import_movie(System.unique_integer([:positive]))
      id
    end
  end

  # Loaded the way the stream controller loads it: provider preloaded, fresh
  # for each request.
  defp movie(id), do: Catalog.get_public_movie(id)

  test "systematic playback failure through open_movie/1 degrades the provider" do
    [first | _] = ids = import_movies(6)
    {failing, [spare]} = Enum.split(ids, 5)

    for id <- failing do
      assert {:error, :no_source_available} = Embedplay.open_movie(movie(id))
      assert_received {:resolver_called, "/resolve"}
    end

    assert %{status: :degraded, reason: "no_source_available", active: true} =
             Embedplay.health()

    assert {:error, :provider_degraded} = Embedplay.open_movie(movie(spare))
    assert {:error, :provider_degraded} = Embedplay.open_movie(movie(first))
    refute_received {:resolver_called, _path}
  end

  test "a degraded provider fails open_movie/1 fast without starting a resolution" do
    [id] = import_movies(1)
    {:ok, _provider} = Providers.mark_embedplay_degraded(:resolver_outdated)

    assert {:error, :provider_degraded} = Embedplay.open_movie(movie(id))
    refute_received {:resolver_called, _path}
    assert %{window: %{successes: 0, failures: 0, transient: 0}} = Embedplay.health()
  end

  test "health/0 reports the persisted state and the observation window" do
    [id] = import_movies(1)
    assert {:error, :no_source_available} = Embedplay.open_movie(movie(id))

    assert %{
             status: :healthy,
             active: true,
             reason: nil,
             degraded_at: nil,
             window: %{failures: 1, streak: %{failures: 1, movies: 1}}
           } = Embedplay.health()
  end
end
