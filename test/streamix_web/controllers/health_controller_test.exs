defmodule StreamixWeb.HealthControllerTest do
  use StreamixWeb.ConnCase, async: false

  setup do
    prior = Application.get_env(:streamix, :operational_health_module)
    Application.put_env(:streamix, :operational_health_module, __MODULE__.HealthStub)

    on_exit(fn ->
      if prior do
        Application.put_env(:streamix, :operational_health_module, prior)
      else
        Application.delete_env(:streamix, :operational_health_module)
      end

      Application.delete_env(:streamix, :operational_health_test_snapshot)
    end)

    :ok
  end

  test "liveness remains shallow and returns 200", %{conn: conn} do
    conn = get(conn, ~p"/api/health")

    assert %{"status" => "ok", "timestamp" => _timestamp} = json_response(conn, 200)
  end

  test "readiness returns 200 for degraded optional services", %{conn: conn} do
    set_snapshot(%{
      status: :degraded,
      checks: %{semantic_search: %{status: :degraded}},
      timestamp: DateTime.utc_now()
    })

    conn = get(conn, ~p"/api/health/ready")

    assert %{
             "status" => "degraded",
             "checks" => %{"semantic_search" => %{"status" => "degraded"}}
           } = json_response(conn, 200)
  end

  test "readiness returns 503 for unavailable required services", %{conn: conn} do
    set_snapshot(%{
      status: :unavailable,
      checks: %{database: %{status: :unavailable}},
      timestamp: DateTime.utc_now()
    })

    conn = get(conn, ~p"/api/health/ready")

    assert %{
             "status" => "unavailable",
             "checks" => %{"database" => %{"status" => "unavailable"}}
           } = json_response(conn, 503)
  end

  defp set_snapshot(snapshot) do
    Application.put_env(:streamix, :operational_health_test_snapshot, snapshot)
  end

  defmodule HealthStub do
    @moduledoc false

    def snapshot do
      Application.fetch_env!(:streamix, :operational_health_test_snapshot)
    end
  end
end
