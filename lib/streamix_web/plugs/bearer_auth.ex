defmodule StreamixWeb.Plugs.BearerAuth do
  @moduledoc """
  Authenticates API requests via a `Authorization: Bearer <session-token>`
  header and assigns the resolved user to `conn.assigns.current_user`.

  Centralises the pattern that was previously duplicated across
  `FavoritesController`, `HistoryController`, `TelemetryController`,
  `ProvidersController`, `AuthController` and (broken)
  `RecommendationsController` — each version decoded the Bearer header,
  URL-base64-decoded the token, and called
  `Accounts.get_user_by_session_token/1`. The old
  `RecommendationsController` accidentally relied on
  `conn.assigns.current_scope.user`, which is only set by the `:browser`
  pipeline's `fetch_current_scope_for_user`; the `:api_v1` pipeline
  never sets it, so every recommendation request 401'd even with a
  valid Bearer token.

  ## Modes

    * `plug StreamixWeb.Plugs.BearerAuth` — **required**. Missing /
      invalid tokens get a 401 and `halt/1`.
    * `plug StreamixWeb.Plugs.BearerAuth, optional: true` — **optional**.
      A missing header keeps the connection going without a
      `:current_user` assign (useful when an endpoint has a
      "personalized if logged in" branch).

  Downstream code should read `conn.assigns[:current_user]` and treat
  `nil` as "anonymous".
  """

  import Plug.Conn

  alias Streamix.Accounts

  @type opts :: [optional: boolean()]

  @spec init(opts()) :: opts()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), opts()) :: Plug.Conn.t()
  def call(conn, opts) do
    case authenticate(conn) do
      {:ok, user} ->
        assign(conn, :current_user, user)

      :error ->
        if Keyword.get(opts, :optional, false) do
          assign(conn, :current_user, nil)
        else
          reject(conn)
        end
    end
  end

  defp authenticate(conn) do
    with token_str when is_binary(token_str) <- get_bearer_token(conn),
         {:ok, token} <- decode_token(token_str),
         {user, _inserted_at} <- Accounts.get_user_by_session_token(token) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  # Accept both padded and unpadded url-safe base64. The TV client
  # emits padded output, `Base.url_encode64/1` in server-side tests
  # emits unpadded — a loose decode catches both without leaking the
  # distinction into every call site.
  defp decode_token(bin) do
    case Base.url_decode64(bin, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> Base.url_decode64(bin)
    end
  end

  defp get_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) > 0 -> token
      [raw] when is_binary(raw) -> fallback_bearer(raw)
      _ -> nil
    end
  end

  # Some clients lower-case or omit the scheme separator — be lenient.
  defp fallback_bearer(raw) do
    case String.split(raw, " ", parts: 2) do
      ["bearer", token] when byte_size(token) > 0 -> token
      _ -> nil
    end
  end

  defp reject(conn) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{
      error: %{code: "unauthorized", message: "Invalid or missing Bearer token"}
    })
    |> halt()
  end
end
