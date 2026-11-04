defmodule StreamixWeb.Plugs.BearerAuth do
  @moduledoc """
  Authenticates API requests using an `Authorization: Bearer <session-token>` header.
  Assigns the same `Accounts.Scope` used by the browser to `:current_scope` and
  the decoded token to `:current_session_token`.

  Required mode returns a stable 401 error and halts on missing or invalid tokens.
  With `optional: true`, anonymous requests continue with both assigns set to nil.
  Downstream authenticated actions read `conn.assigns.current_scope.user`.
  """

  import Plug.Conn

  alias Streamix.Accounts
  alias StreamixWeb.Api.V1.Response

  @type opts :: [optional: boolean()]

  @spec init(opts()) :: opts()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), opts()) :: Plug.Conn.t()
  def call(conn, opts) do
    case authenticate(conn) do
      {:ok, user, token} ->
        conn
        |> assign(:current_scope, Accounts.scope_for_user(user))
        |> assign(:current_session_token, token)

      :error ->
        if Keyword.get(opts, :optional, false) do
          conn
          |> assign(:current_scope, nil)
          |> assign(:current_session_token, nil)
        else
          reject(conn)
        end
    end
  end

  defp authenticate(conn) do
    with token_str when is_binary(token_str) <- get_bearer_token(conn),
         {:ok, token} <- decode_token(token_str),
         {user, _inserted_at} <- Accounts.get_user_by_session_token(token) do
      {:ok, user, token}
    else
      _ -> :error
    end
  end

  # Accept both padded and unpadded url-safe base64 without leaking the
  # distinction into every call site.
  defp decode_token(bin) do
    case Base.url_decode64(bin, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> Base.url_decode64(bin)
    end
  end

  defp get_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      [raw] when is_binary(raw) -> parse_bearer(raw)
      _ -> nil
    end
  end

  # RFC 9110 authentication schemes are case-insensitive. Accept one or
  # more spaces, but never accept a missing scheme separator.
  defp parse_bearer(raw) do
    case String.split(raw, ~r/\s+/, parts: 2, trim: true) do
      [scheme, token] when byte_size(token) > 0 ->
        if String.downcase(scheme) == "bearer", do: token

      _ ->
        nil
    end
  end

  defp reject(conn) do
    :telemetry.execute(
      [:streamix, :auth, :bearer, :rejected],
      %{count: 1},
      %{ip: Accounts.client_ip(conn), reason: :invalid_or_missing}
    )

    conn
    |> Response.error(:unauthorized, "unauthorized", "Invalid or missing Bearer token")
    |> halt()
  end
end
