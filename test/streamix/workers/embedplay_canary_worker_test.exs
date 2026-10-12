defmodule Streamix.Workers.EmbedplayCanaryWorkerTest do
  use Streamix.DataCase, async: false
  use Oban.Testing, repo: Streamix.Repo

  alias Streamix.{Catalog, Embedplay, Providers}
  alias Streamix.Embedplay.{Health, HealthWindow}
  alias Streamix.Workers.EmbedplayCanaryWorker

  setup do
    original = Application.get_env(:streamix, :embedplay, [])

    Application.put_env(:streamix, :embedplay,
      enabled: true,
      resolver_url: "http://127.0.0.1:9999",
      resolver_token: "test-only",
      http_options: [plug: {Req.Test, __MODULE__}]
    )

    # The application's window is shared by every test that resolves; start
    # clean and leave it clean.
    reset_window = fn -> :sys.replace_state(Health, fn _window -> HealthWindow.new() end) end
    reset_window.()
    on_exit(reset_window)
    on_exit(fn -> Application.put_env(:streamix, :embedplay, original) end)
    :ok
  end

  # The resolver is stubbed: it reports every request to the test and answers
  # with `status`/`body`.
  defp stub_resolver(status, body) do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, request, conn} = Plug.Conn.read_body(conn)
      send(owner, {:resolve, Jason.decode!(request)["tmdb_id"]})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  defp resolver_works,
    do: stub_resolver(200, ~s({"manifest_url":"https://93.184.216.34/master.m3u8"}))

  defp resolver_broken, do: stub_resolver(502, ~s({"error":{"code":"stream_unavailable"}}))

  defp import_movie do
    {:ok, id} = Embedplay.import_movie(System.unique_integer([:positive]))
    Catalog.get_movie!(id)
  end

  defp health_status, do: Providers.get_embedplay_provider().health_status

  describe "while degraded" do
    setup do
      movie = import_movie()
      {:ok, _provider} = Providers.mark_embedplay_degraded(:no_source_available)
      %{movie: movie}
    end

    test "a successful probe clears the degraded state", %{movie: movie} do
      resolver_works()

      assert :ok = perform_job(EmbedplayCanaryWorker, %{})

      assert_received {:resolve, tmdb_id}
      assert tmdb_id == movie.tmdb_id
      assert health_status() == :healthy
      assert %{status: :healthy, active: true} = Embedplay.health()
    end

    test "a failed probe keeps it degraded and is not a job error" do
      resolver_broken()

      assert :ok = perform_job(EmbedplayCanaryWorker, %{})

      assert_received {:resolve, _tmdb_id}
      assert health_status() == :degraded
    end

    test "the probe skips a title that just failed when another exists", %{movie: failed} do
      other = import_movie()
      Health.observe(failed.id, {:error, :no_source_available})
      resolver_works()

      assert :ok = perform_job(EmbedplayCanaryWorker, %{})

      assert_received {:resolve, tmdb_id}
      assert tmdb_id == other.tmdb_id
    end

    test "nothing is probed while the operator keeps the provider disabled" do
      {:ok, _provider} =
        Providers.update_provider(Providers.get_embedplay_provider(), %{is_active: false})

      resolver_works()

      assert :ok = perform_job(EmbedplayCanaryWorker, %{})

      refute_received {:resolve, _tmdb_id}
      assert health_status() == :degraded
    end
  end

  describe "while healthy" do
    setup do
      %{movie: import_movie()}
    end

    test "recent real traffic makes the probe unnecessary", %{movie: movie} do
      Health.observe(movie.id, {:ok, %{session_id: "live", resource_id: "r"}})
      resolver_works()

      assert :ok = perform_job(EmbedplayCanaryWorker, %{})

      refute_received {:resolve, _tmdb_id}
    end

    test "an idle hour is probed, and a failure is recorded without tripping" do
      resolver_broken()

      assert :ok = perform_job(EmbedplayCanaryWorker, %{})

      assert_received {:resolve, _tmdb_id}
      assert health_status() == :healthy
      assert %{window: %{failures: 1}} = Embedplay.health()
    end

    test "repeated idle probes over distinct titles do trip" do
      for _ <- 1..4, do: import_movie()
      resolver_broken()

      for _ <- 1..5 do
        # Each probe is the most recent outcome; age it so the next is due.
        :sys.replace_state(Health, fn window ->
          %{window | entries: Enum.map(window.entries, &%{&1 | at: &1.at - 3_600_000})}
        end)

        assert :ok = perform_job(EmbedplayCanaryWorker, %{})
      end

      assert health_status() == :degraded

      assert %{reason: "no_source_available", window: %{streak: %{movies: 5}}} =
               Embedplay.health()
    end
  end

  test "nothing is probed while Embedplay is disabled" do
    import_movie()
    Application.put_env(:streamix, :embedplay, enabled: false)
    resolver_works()

    assert :ok = perform_job(EmbedplayCanaryWorker, %{})

    refute_received {:resolve, _tmdb_id}
  end

  test "a probe in flight blocks the next tick from scheduling another" do
    assert {:ok, %{conflict?: false}} = %{} |> EmbedplayCanaryWorker.new() |> Oban.insert()
    assert {:ok, %{conflict?: true}} = %{} |> EmbedplayCanaryWorker.new() |> Oban.insert()
  end
end
