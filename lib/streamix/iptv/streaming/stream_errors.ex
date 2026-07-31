defmodule Streamix.Iptv.Streaming.StreamErrors do
  @moduledoc """
  Structured error payloads for stream proxy responses.

  The code vocabulary lives in core streaming code so proxy internals can
  classify upstream failures without depending on the web namespace.
  """

  import Plug.Conn

  alias Plug.Conn.Status

  @type code ::
          :upstream_unavailable
          | :upstream_not_found
          | :upstream_timeout
          | :provider_capacity_exhausted
          | :stream_resolution_failed
          | :token_expired
          | :invalid_token
          | :subscription_required
          | :content_not_found
          | :token_unauthorized
          | :unauthorized
          | :unsafe_url
          | :missing_token
          | :unknown

  @errors %{
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
    provider_capacity_exhausted: {
      :service_unavailable,
      "Provider connection capacity is temporarily exhausted",
      retry_after: 5
    },
    stream_resolution_failed: {
      :bad_gateway,
      "Failed to resolve final stream URL",
      retry_after: 60
    },
    token_expired: {:unauthorized, "Stream token expired"},
    invalid_token: {:unauthorized, "Invalid stream token"},
    unauthorized: {:unauthorized, "Unauthorized"},
    missing_token: {:bad_request, "Missing token parameter"},
    subscription_required: {:forbidden, "Subscription required"},
    token_unauthorized: {:forbidden, "Token not authorized for this content"},
    unsafe_url: {:forbidden, "URL blocked by security policy"},
    content_not_found: {:not_found, "Content not found"},
    unknown: {:bad_request, "Stream proxy error"}
  }

  @doc """
  Halts `conn` with the canonical JSON body for the given `code`.
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
    |> put_resp_content_type("application/json")
    |> send_resp(conn_status(status), Jason.encode!(%{error: body}))
    |> Plug.Conn.halt()
  end

  @doc """
  Maps a raw resolve error tuple into one of the canonical stream error codes.
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

  @doc """
  Resolves a canonical code into `{plug_status, message, extras}`.
  """
  @spec resolve(code()) :: {atom(), String.t(), keyword()}
  def resolve(code) do
    case Map.get(@errors, code) do
      {status, msg} -> {status, msg, []}
      {status, msg, extras} -> {status, msg, extras}
      nil -> {:bad_request, "Stream proxy error", []}
    end
  end

  defp conn_status(status) when is_atom(status), do: Status.code(status)

  defp maybe_merge(map, _key, nil), do: map
  defp maybe_merge(map, key, value), do: Map.put(map, key, value)
end
