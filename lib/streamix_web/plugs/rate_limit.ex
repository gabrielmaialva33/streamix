defmodule StreamixWeb.Plugs.RateLimit do
  @moduledoc """
  Rate limiting plug using Hammer.

  Usage in router:
    plug StreamixWeb.Plugs.RateLimit, limit: 10, period: 60_000  # 10 requests per minute

  Rate limits by IP address. Returns 429 Too Many Requests when limit is exceeded.
  """

  import Plug.Conn
  require Logger

  @default_limit 100
  @default_period 60_000

  def init(opts) do
    %{
      limit: Keyword.get(opts, :limit, @default_limit),
      period: Keyword.get(opts, :period, @default_period),
      by: Keyword.get(opts, :by, :ip)
    }
  end

  def call(conn, opts) do
    key = build_key(conn, opts.by)
    bucket = "rate_limit:#{key}"

    case Hammer.check_rate(bucket, opts.period, opts.limit) do
      {:allow, count} ->
        conn
        |> put_rate_limit_headers(opts.limit, opts.limit - count, opts.period)

      {:deny, retry_after} ->
        Logger.warning("Rate limit exceeded for #{key}")

        conn
        |> put_rate_limit_headers(opts.limit, 0, opts.period)
        |> put_resp_header("retry-after", Integer.to_string(div(retry_after, 1000)))
        |> put_status(:too_many_requests)
        |> Phoenix.Controller.json(%{
          error: "Too many requests",
          message: "Rate limit exceeded. Please try again later.",
          retry_after: div(retry_after, 1000)
        })
        |> halt()
    end
  end

  defp build_key(conn, :ip) do
    conn.remote_ip
    |> Tuple.to_list()
    |> Enum.join(".")
  end

  defp build_key(conn, :user) do
    case conn.assigns[:current_scope] do
      %{user: %{id: user_id}} -> "user:#{user_id}"
      _ -> build_key(conn, :ip)
    end
  end

  defp put_rate_limit_headers(conn, limit, remaining, period) do
    conn
    |> put_resp_header("x-ratelimit-limit", Integer.to_string(limit))
    |> put_resp_header("x-ratelimit-remaining", Integer.to_string(max(0, remaining)))
    |> put_resp_header("x-ratelimit-reset", Integer.to_string(div(period, 1000)))
  end
end
