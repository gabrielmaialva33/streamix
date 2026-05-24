defmodule StreamixWeb.InternalDiagController do
  @moduledoc """
  Catch-all for client-side diagnostic beacons. These exist purely so a
  bug we can't reproduce in dev (Safari iOS stuck skeleton on `/`, see
  HomeLive) can be observed in prod logs without shipping a full APM.
  """

  use StreamixWeb, :controller

  require Logger

  def home_stuck(conn, params) do
    Logger.warning(fn ->
      [
        "[home-stuck] ",
        "ip=",
        format_ip(conn.remote_ip),
        " ",
        params |> Map.take(~w(ua transport connected standalone iosWebkit at)) |> inspect()
      ]
    end)

    send_resp(conn, 204, "")
  end

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(_), do: "?"
end
