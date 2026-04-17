defmodule StreamixWeb.Plugs.MetricsAuth do
  @moduledoc """
  HTTP basic auth gate for the /metrics scrape endpoint.

  Credentials come from runtime config (`config :streamix, :metrics_auth`)
  or the `METRICS_USER` / `METRICS_PASSWORD` env vars. When neither is set
  the endpoint is refused with 404 so we don't leak that it exists.
  """

  import Plug.Conn

  @realm "Streamix metrics"

  def init(opts), do: opts

  def call(conn, _opts) do
    case credentials() do
      {user, pass} when is_binary(user) and is_binary(pass) ->
        enforce(conn, user, pass)

      _ ->
        conn
        |> send_resp(404, "")
        |> halt()
    end
  end

  defp enforce(conn, user, pass) do
    expected = "Basic " <> Base.encode64("#{user}:#{pass}")

    case get_req_header(conn, "authorization") do
      [^expected] ->
        conn

      _ ->
        conn
        |> put_resp_header("www-authenticate", ~s(Basic realm="#{@realm}"))
        |> send_resp(401, "")
        |> halt()
    end
  end

  defp credentials do
    cfg = Application.get_env(:streamix, :metrics_auth, [])

    user = cfg[:user] || System.get_env("METRICS_USER")
    pass = cfg[:password] || System.get_env("METRICS_PASSWORD")

    {user, pass}
  end
end
