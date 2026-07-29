defmodule StreamixWeb.HealthController do
  use StreamixWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok", timestamp: DateTime.utc_now()})
  end

  def ready(conn, _params) do
    snapshot = health_module().snapshot()
    status = if snapshot.status == :unavailable, do: :service_unavailable, else: :ok

    conn
    |> put_status(status)
    |> json(snapshot)
  end

  defp health_module do
    Application.get_env(:streamix, :operational_health_module, Streamix.OperationalHealth)
  end
end
