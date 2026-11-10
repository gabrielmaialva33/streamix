defmodule StreamixWeb.Plugs.BearerAuth do
  @moduledoc """
  Authenticates API requests using an `Authorization: Bearer <session-token>` header.
  Assigns the same `Accounts.Scope` used by the browser to `:current_scope` and
  the decoded token to `:current_session_token`.

  Required mode returns a stable 401 error and halts on missing or invalid tokens.
  With `optional: true`, anonymous requests continue with both assigns set to nil.
  Downstream authenticated actions read `conn.assigns.current_scope.user`.

  ## Token shape

  The bearer token is the URL-safe base64 of the 32-byte session token
  followed by the 32-byte library secret (`Streamix.Library`). The secret
  never reaches the database; together with the session's stored wrap it
  unlocks the user's library key, assigned as `:current_library_key`.
  Tokens without a secret predate the encrypted library and are rejected,
  so the client logs in again.
  """

  import Plug.Conn

  alias Streamix.{Accounts, Library}
  alias StreamixWeb.Api.V1.Response

  @session_token_bytes 32

  @type opts :: [optional: boolean()]

  @spec init(opts()) :: opts()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), opts()) :: Plug.Conn.t()
  def call(conn, opts) do
    case authenticate(conn) do
      {:ok, user, token, library_key} ->
        conn
        |> assign(:current_scope, Accounts.scope_for_user(user, library_key))
        |> assign(:current_session_token, token)
        |> assign(:current_library_key, library_key)

      :error ->
        if Keyword.get(opts, :optional, false) do
          conn
          |> assign(:current_scope, nil)
          |> assign(:current_session_token, nil)
          |> assign(:current_library_key, nil)
        else
          reject(conn)
        end
    end
  end

  defp authenticate(conn) do
    with token_str when is_binary(token_str) <- get_bearer_token(conn),
         {:ok, credentials} <- decode_token(token_str),
         {:ok, token, library_secret} <- split_credentials(credentials),
         {user, _inserted_at, sealed_library_key} <- Accounts.get_session_by_token(token),
         {:ok, library_key} <- Library.open_session(user.id, library_secret, sealed_library_key) do
      {:ok, user, token, library_key}
    else
      _ -> :error
    end
  end

  @doc """
  Encodes the bearer token handed to API clients at login: the session token
  followed by the library secret, URL-safe base64.
  """
  @spec encode_token(binary(), binary()) :: String.t()
  def encode_token(session_token, library_secret)
      when byte_size(session_token) == @session_token_bytes do
    Base.url_encode64(session_token <> library_secret)
  end

  defp split_credentials(<<token::binary-size(@session_token_bytes), library_secret::binary>>)
       when byte_size(library_secret) > 0,
       do: {:ok, token, library_secret}

  defp split_credentials(_credentials), do: :error

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
