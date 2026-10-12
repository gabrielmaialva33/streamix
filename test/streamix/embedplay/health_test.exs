defmodule Streamix.Embedplay.HealthTest do
  use Streamix.DataCase, async: false

  import ExUnit.CaptureLog

  alias Streamix.Embedplay.Health
  alias Streamix.Providers

  @no_source {:error, :no_source_available}

  setup do
    original = Application.get_env(:streamix, :embedplay, [])
    Application.put_env(:streamix, :embedplay, enabled: true)
    on_exit(fn -> Application.put_env(:streamix, :embedplay, original) end)

    # Recovery logs at info; the suite runs at :warning.
    Logger.put_module_level(Health, :info)
    on_exit(fn -> Logger.delete_module_level(Health) end)

    # A private window per test, apart from the application's.
    server = :embedplay_health_test
    start_supervised!({Health, name: server})
    {:ok, provider} = Providers.ensure_embedplay_provider()

    %{server: server, provider: provider}
  end

  defp fail_distinct(server, ids, result \\ @no_source) do
    Enum.each(ids, &Health.observe(&1, result, server: server))
  end

  defp reload, do: Providers.get_embedplay_provider()

  describe "tripping" do
    test "five distinct no-source failures degrade the provider, never touching is_active",
         %{server: server} do
      log = capture_log(fn -> fail_distinct(server, 1..4) end)
      assert %{health_status: :healthy} = reload()
      refute log =~ "degraded"

      log = capture_log(fn -> fail_distinct(server, [5]) end)

      assert %{
               health_status: :degraded,
               degraded_reason: "no_source_available",
               degraded_at: %DateTime{},
               is_active: true
             } = reload()

      assert log =~ "[warning]"
      assert log =~ "resolution degraded: reason=no_source_available"
      assert log =~ "failures=5 distinct_movies=5"
    end

    test "resolver_outdated trips on the second distinct movie", %{server: server} do
      log = capture_log(fn -> fail_distinct(server, [1, 1, 2], {:error, :resolver_outdated}) end)

      assert %{health_status: :degraded, degraded_reason: "resolver_outdated"} = reload()
      assert log =~ "reason=resolver_outdated"
    end

    test "transient errors alone never trip", %{server: server} do
      for reason <- [:upstream_timeout, :provider_capacity_exhausted, :stream_resolution_failed] do
        fail_distinct(server, 1..20, {:error, reason})
      end

      assert %{health_status: :healthy} = reload()
      assert %{transient: 60, failures: 0} = Health.summary(server: server)
    end

    test "further failures while degraded neither re-persist nor re-log", %{server: server} do
      fail_distinct(server, 1..5)
      %{degraded_at: degraded_at} = reload()

      log = capture_log(fn -> fail_distinct(server, 6..9) end)

      refute log =~ "resolution degraded"
      assert %{health_status: :degraded, degraded_at: ^degraded_at} = reload()
    end
  end

  describe "recovery" do
    test "the first success after a trip recovers and logs at info", %{server: server} do
      fail_distinct(server, 1..5)

      log =
        capture_log(fn ->
          Health.observe(6, {:ok, %{session_id: "s", resource_id: "r"}}, server: server)
        end)

      assert %{health_status: :healthy, degraded_reason: nil, degraded_at: nil} = reload()
      assert log =~ "[info]"
      assert log =~ "resolution recovered: previous_reason=no_source_available"
    end

    test "recovery never re-enables a provider the operator disabled", %{server: server} do
      fail_distinct(server, 1..5)
      {:ok, _provider} = Providers.update_provider(reload(), %{is_active: false})

      Health.observe(6, {:ok, %{}}, server: server)

      assert %{health_status: :healthy, is_active: false} = reload()
    end

    test "a probe clears a degraded state persisted before this process existed",
         %{server: server} do
      {:ok, _provider} = Providers.mark_embedplay_degraded(:resolver_outdated)

      Health.observe(1, {:ok, %{}}, server: server)
      assert %{health_status: :degraded} = reload()

      Health.observe(2, {:ok, %{}}, server: server, source: :canary, recover: true)
      assert %{health_status: :healthy} = reload()
    end
  end

  describe "guard/3" do
    test "fails fast while degraded without running the open", %{server: server} do
      {:ok, _provider} = Providers.mark_embedplay_degraded(:no_source_available)
      degraded = reload()

      open = fn ->
        send(self(), :opened)
        {:ok, %{}}
      end

      assert {:error, :provider_degraded} =
               Health.guard(%{id: 1, provider: degraded}, open, server: server)

      # Without a preloaded provider the persisted state is read instead.
      assert {:error, :provider_degraded} = Health.guard(%{id: 1}, open, server: server)

      refute_received :opened
      assert %{successes: 0, failures: 0} = Health.summary(server: server)
    end

    test "records the outcome of every open it lets through", %{
      server: server,
      provider: provider
    } do
      for id <- 1..5 do
        assert @no_source =
                 Health.guard(%{id: id, provider: provider}, fn -> @no_source end, server: server)
      end

      assert %{health_status: :degraded} = reload()
    end

    test "an unreachable window never breaks playback", %{provider: provider} do
      result = {:ok, %{session_id: "s", resource_id: "r"}}

      assert ^result =
               Health.guard(%{id: 1, provider: provider}, fn -> result end, server: :not_running)

      assert Health.summary(server: :not_running) == nil
    end
  end

  test "status/1 combines the persisted state with the window", %{server: server} do
    assert %{status: :healthy, active: true, reason: nil, window: %{successes: 0}} =
             Health.status(server: server)

    fail_distinct(server, 1..5)

    assert %{
             status: :degraded,
             reason: "no_source_available",
             degraded_at: %DateTime{},
             window: %{failures: 5, streak: %{failures: 5, movies: 5}}
           } = Health.status(server: server)

    Application.put_env(:streamix, :embedplay, enabled: false)
    assert %{status: :disabled, active: false} = Health.status(server: server)
  end
end
