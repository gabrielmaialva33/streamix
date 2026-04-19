defmodule StreamixWeb.StreamErrors do
  @moduledoc """
  Structured error payloads for `/api/stream/proxy`.

  A flat `%{error: "failed"}` body is fine for a browser that renders
  an HTML page, but the TV / mobile players need to distinguish
  "provider backend is down, try again in 2 minutes" from "this content
  was removed" or "your token is bad" — otherwise every failure looks
  identical and the player shows the same generic "failed to load"
  message for all of them.

  Every response follows the same shape:

      {
        "error": {
          "code": "upstream_unavailable",
          "message": "Provider backend returned 502",
          "retry_after": 120
        }
      }

    * `code`         — stable machine identifier, safe to switch on
    * `message`      — human copy the client can render verbatim
    * `retry_after`  — seconds, present only on transient failures so
                       clients know whether to auto-retry or give up

  Keeping this as a module instead of inlining maps in the controller
  means the `code` vocabulary stays discoverable (one grep away) and
  the TV team can pin against a fixed list.
  """

  import Plug.Conn

  @type code ::
          :upstream_unavailable
          | :upstream_not_found
          | :upstream_timeout
          | :stream_resolution_failed
          | :token_expired
          | :invalid_token
          | :subscription_required
          | :content_not_found
          | :token_unauthorized
          | :unsafe_url
          | :missing_token
          | :unknown

  @errors %{
    # Provider-side failures — the TV player should display a friendly
    # "fonte indisponível, tente novamente" and offer an auto-retry.
    upstream_unavailable: {
      :bad_gateway,
      "Provider backend is currently unavailable",
      retry_after: 120
    },
    upstream_timeout: {
      :gateway_timeout,
      "Provider timed out before returning a stream URL",
      retry_after: 60
    },
    upstream_not_found: {
      :not_found,
      "Provider returned 404 — content may have been removed upstream"
    },
    stream_resolution_failed: {
      :bad_gateway,
      "Failed to resolve final stream URL",
      retry_after: 60
    },

    # Token / authorization failures — no retry, the client should
    # bounce to login or surface the subscription gate.
    token_expired: {:unauthorized, "Stream token expired"},
    invalid_token: {:unauthorized, "Invalid stream token"},
    missing_token: {:bad_request, "Missing token parameter"},
    subscription_required: {:forbidden, "Subscription required"},
    token_unauthorized: {:forbidden, "Token not authorized for this content"},
    unsafe_url: {:forbidden, "URL blocked by security policy"},

    # Terminal lookups.
    content_not_found: {:not_found, "Content not found"},

    # Ultimate fallback — intentionally generic so we never emit a
    # leaky stacktrace over the wire.
    unknown: {:bad_request, "Stream proxy error"}
  }

  @doc """
  Halts `conn` with the canonical JSON body for the given `code`.

  Pass `override_message: "..."` when the controller has more context
  than the default copy — e.g. the concrete HTTP status we got from
  upstream. The `code` still drives `retry_after` and the HTTP status.
  """
  @spec halt(Plug.Conn.t(), code(), keyword()) :: Plug.Conn.t()
  def halt(conn, code, opts \\ []) do
    {status, message, extras} = resolve(code)
    final_message = Keyword.get(opts, :override_message, message)

    body =
      %{code: code, message: final_message}
      |> maybe_merge(:retry_after, extras[:retry_after])

    conn
    |> put_status(status)
    |> Phoenix.Controller.json(%{error: body})
    |> Plug.Conn.halt()
  end

  @doc """
  Maps a raw resolve error tuple (the shape `resolve_final_url/2`
  emits) into one of our canonical codes. Keeps the pattern matching
  in one place so controllers don't drift.
  """
  @spec code_from_reason(term()) :: code()
  def code_from_reason({:unexpected_status, 404}), do: :upstream_not_found

  def code_from_reason({:unexpected_status, status}) when status in 500..599,
    do: :upstream_unavailable

  def code_from_reason({:unexpected_status, _}), do: :stream_resolution_failed
  def code_from_reason(:timeout), do: :upstream_timeout

  def code_from_reason(%{__struct__: mod, reason: :timeout})
      when mod in [Req.TransportError, Mint.TransportError],
      do: :upstream_timeout

  def code_from_reason(%{__struct__: mod}) when mod in [Req.TransportError, Mint.TransportError],
    do: :upstream_unavailable

  def code_from_reason(_), do: :stream_resolution_failed

  # --- Private ---

  defp resolve(code) do
    case Map.get(@errors, code) do
      {status, msg} -> {status, msg, []}
      {status, msg, extras} -> {status, msg, extras}
      nil -> {:bad_request, "Stream proxy error", []}
    end
  end

  defp maybe_merge(map, _key, nil), do: map
  defp maybe_merge(map, key, value), do: Map.put(map, key, value)
end
