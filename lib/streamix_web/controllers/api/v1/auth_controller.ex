defmodule StreamixWeb.Api.V1.AuthController do
  @moduledoc """
  REST API for mobile/TV app authentication.
  Uses session tokens (same as web) but returned as JSON instead of cookies.
  """
  use StreamixWeb, :controller

  alias Streamix.Accounts

  @doc """
  POST /api/v1/auth/register
  Creates a new user account and returns session token.
  """
  def register(conn, %{"email" => email, "password" => password} = params) do
    case Accounts.register_user_with_password(%{
           email: email,
           password: password,
           name: params["name"]
         }) do
      {:ok, user} ->
        token = Accounts.generate_user_session_token(user, ip_info(conn))

        conn
        |> put_status(:created)
        |> json(%{
          token: Base.url_encode64(token),
          user: serialize_user(user)
        })

      {:error, changeset} ->
        errors = format_changeset_errors(changeset)

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "validation_failed", message: errors}})
    end
  end

  def register(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "missing_params", message: "Email and password are required"}})
  end

  @doc """
  POST /api/v1/auth/login
  Authenticates user and returns session token.
  """
  def login(conn, %{"email" => email, "password" => password}) do
    case Accounts.get_user_by_email_and_password(email, password) do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: %{code: "invalid_credentials", message: "Invalid email or password"}})

      user ->
        token = Accounts.generate_user_session_token(user, ip_info(conn))

        json(conn, %{
          token: Base.url_encode64(token),
          user: serialize_user(user)
        })
    end
  end

  def login(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "missing_params", message: "Email and password are required"}})
  end

  @doc """
  GET /api/v1/auth/me
  Returns current user from session token.
  Expects: Authorization: Bearer <base64_token>
  """
  def me(conn, _params) do
    case get_token_user(conn) do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: %{code: "unauthorized", message: "Invalid or expired token"}})

      {user, _inserted_at} ->
        json(conn, %{user: serialize_user(user)})
    end
  end

  @doc """
  POST /api/v1/auth/logout
  Invalidates the session token.
  """
  def logout(conn, _params) do
    case get_bearer_token(conn) do
      nil ->
        send_resp(conn, 204, "")

      token_str ->
        case Base.url_decode64(token_str) do
          {:ok, token} ->
            Accounts.delete_user_session_token(token)
            send_resp(conn, 204, "")

          :error ->
            send_resp(conn, 204, "")
        end
    end
  end

  # Helpers

  defp get_token_user(conn) do
    case get_bearer_token(conn) do
      nil ->
        nil

      token_str ->
        case Base.url_decode64(token_str) do
          {:ok, token} -> Accounts.get_user_by_session_token(token)
          :error -> nil
        end
    end
  end

  defp get_bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp ip_info(conn) do
    %{
      ip_address: conn.remote_ip |> :inet.ntoa() |> to_string(),
      user_agent: Plug.Conn.get_req_header(conn, "user-agent") |> List.first()
    }
  end

  defp serialize_user(user) do
    %{
      id: user.id,
      email: user.email,
      name: Map.get(user, :name),
      role: user.role
    }
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end
end
