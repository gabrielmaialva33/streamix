defmodule StreamixWeb.Api.V1.StatusController do
  @moduledoc """
  Provider health surface for TV/mobile clients.

  Exposes the per-provider circuit-breaker state so clients can tell
  the difference between "my session is broken" and "the upstream
  provider is down right now" — and render the right banner either way.

  Intentionally separate from the liveness probe at `/api/health`:
  that one only answers "is Streamix itself up?"; this one answers
  "is the IPTV provider reachable?".
  """

  use StreamixWeb, :controller

  alias Streamix.Iptv

  @doc """
  GET /api/v1/providers/status

  Returns every active public/global provider with its current
  classification (`:healthy | :degraded | :unhealthy | :unknown`),
  a human message the client can render verbatim, and the timestamps
  of last success / last error.

  Also includes a roll-up `overall.status` so a client only interested
  in "should I show a banner?" can check one field.
  """
  def index(conn, _params) do
    reports = Iptv.list_provider_health_reports()
    overall = Iptv.provider_health_summary()

    json(conn, %{
      overall: %{
        status: overall.status,
        counts: overall.counts
      },
      providers: reports
    })
  end
end
