defmodule StreamixWeb.HealthController do
  use StreamixWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok", timestamp: DateTime.utc_now()})
  end
end
