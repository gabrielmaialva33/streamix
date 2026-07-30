defmodule StreamixWeb.InternalDiagController do
  @moduledoc """
  Catch-all for client-side diagnostic beacons. These exist purely so a
  bug we can't reproduce in dev (Safari iOS stuck skeleton on `/`, see
  HomeLive) can be observed in prod logs without shipping a full APM.
  """

  use StreamixWeb, :controller

  require Logger

  alias Streamix.Accounts
  alias Streamix.SafeLog

  @diagnostic_fields [
    {"ua", 384},
    {"transport", 64},
    {"connected", 32},
    {"standalone", 32},
    {"iosWebkit", 32},
    {"at", 64}
  ]

  def home_stuck(conn, params) do
    Logger.warning(fn ->
      [
        "[home-stuck] ",
        "ip=",
        Accounts.client_ip(conn),
        " ",
        params |> bounded_diagnostics() |> inspect()
      ]
    end)

    send_resp(conn, 204, "")
  end

  defp bounded_diagnostics(params) do
    Map.new(@diagnostic_fields, fn {field, limit} ->
      {field, params |> Map.get(field) |> SafeLog.scalar(limit)}
    end)
  end
end
