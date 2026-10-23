defmodule StreamixWeb.Api.V1.AuthController do
  @moduledoc """
  REST API for mobile/TV app authentication.
  Uses session tokens (same as web) but returned as JSON instead of cookies.
  """
  use StreamixWeb, :controller

  alias Streamix.{Accounts, Library}
  alias StreamixWeb.Api.V1.Response
  alias StreamixWeb.Plugs.BearerAuth

  plug StreamixWeb.Plugs.BearerAuth when action == :me
  plug StreamixWeb.Plugs.BearerAuth, [optional: true] when action == :logout

  @doc """
  POST /api/v1/auth/register
  Creates a new user account and returns session token.
  """
  def register(conn, %{"email" => email, "password" => password} = params)
      when is_binary(email) and is_binary(password) do
    case Accounts.register_user_with_password(%{
           email: email,
           password: password,
           name: params["name"]
         }) do
      {:ok, user} ->
        case issue_token(conn, user, password) do
          {:ok, token} ->
            conn
            |> put_status(:created)
            |> json(%{token: token, user: serialize_user(user)})

          {:error, :locked} ->
            library_locked(conn)
        end

      {:error, changeset} ->
        Response.error(
          conn,
          :unprocessable_entity,
          "validation_failed",
          Response.changeset_message(changeset)
        )
    end
  end

  def register(conn, _params) do
    Response.error(
      conn,
      :bad_request,
      "missing_params",
      "Email and password are required"
    )
  end

  @doc """
  POST /api/v1/auth/login
  Authenticates user and returns session token.
  """
  def login(conn, %{"email" => email, "password" => password})
      when is_binary(email) and is_binary(password) do
    case Accounts.get_user_by_email_and_password(email, password) do
      nil ->
        :telemetry.execute(
          [:streamix, :auth, :login, :failed],
          %{count: 1},
          %{
            email_fingerprint: email_fingerprint(email),
            ip: format_remote_ip(conn),
            reason: :invalid_credentials
          }
        )

        Response.error(
          conn,
          :unauthorized,
          "invalid_credentials",
          "Invalid email or password"
        )

      user ->
        case issue_token(conn, user, password) do
          {:ok, token} -> json(conn, %{token: token, user: serialize_user(user)})
          {:error, :locked} -> library_locked(conn)
        end
    end
  end

  def login(conn, _params) do
    Response.error(
      conn,
      :bad_request,
      "missing_params",
      "Email and password are required"
    )
  end

  @doc """
  GET /api/v1/auth/me
  Returns current user from session token.
  Expects: Authorization: Bearer <base64_token>
  """
  def me(conn, _params) do
    json(conn, %{user: serialize_user(conn.assigns.current_user)})
  end

  @doc """
  POST /api/v1/auth/logout
  Invalidates the session token.
  """
  def logout(conn, _params) do
    if token = conn.assigns.current_session_token do
      Accounts.delete_user_session_token(token)
    end

    send_resp(conn, 204, "")
  end

  # The password is in hand only at register/login, so the library key is
  # unlocked here and wrapped for the new session; the client keeps the
  # secret as the second half of its bearer token (see BearerAuth).
  defp issue_token(conn, user, password) do
    with {:ok, library_key} <- Library.unlock(user, password) do
      {library_secret, sealed_library_key} = Library.seal_session(library_key)
      token = Accounts.generate_user_session_token(user, ip_info(conn), sealed_library_key)
      {:ok, BearerAuth.encode_token(token, library_secret)}
    end
  end

  defp library_locked(conn) do
    Response.error(
      conn,
      :unauthorized,
      "library_locked",
      "This password does not open the account's library"
    )
  end

  defp ip_info(conn) do
    %{
      ip_address: Accounts.client_ip(conn),
      user_agent: Plug.Conn.get_req_header(conn, "user-agent") |> List.first()
    }
  end

  defp format_remote_ip(conn), do: Accounts.client_ip(conn)

  defp serialize_user(user) do
    user = Accounts.preload_role(user)

    %{
      id: user.id,
      email: user.email,
      name: Map.get(user, :name),
      role: user.role.name
    }
  end

  defp email_fingerprint(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end
