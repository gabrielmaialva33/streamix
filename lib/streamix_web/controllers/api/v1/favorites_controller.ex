defmodule StreamixWeb.Api.V1.FavoritesController do
  @moduledoc """
  REST API for favorites management.
  Requires Bearer token authentication.
  """
  use StreamixWeb, :controller

  alias Streamix.Accounts
  alias Streamix.Iptv.Favorites

  plug :authenticate

  @doc """
  GET /api/v1/favorites
  Lists user's favorites, optionally filtered by type.
  """
  def index(conn, params) do
    user = conn.assigns.current_user
    opts = [content_type: params["type"], limit: parse_int(params["limit"], 100)]
    favorites = Favorites.list(user.id, opts)

    json(conn, %{
      favorites:
        Enum.map(favorites, fn f ->
          %{
            id: f.id,
            content_type: f.content_type,
            content_id: f.content_id,
            created_at: f.inserted_at
          }
        end)
    })
  end

  @doc """
  POST /api/v1/favorites
  Adds a favorite. Body: { "type": "movie", "content_id": 123 }
  """
  def create(conn, %{"type" => type, "content_id" => content_id}) do
    user = conn.assigns.current_user

    case Favorites.add(user.id, type, content_id) do
      {:ok, fav} ->
        conn
        |> put_status(:created)
        |> json(%{
          id: fav.id,
          content_type: fav.content_type,
          content_id: fav.content_id
        })

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "already_exists", message: "Already in favorites"}})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "missing_params", message: "type and content_id required"}})
  end

  @doc """
  DELETE /api/v1/favorites/:type/:content_id
  Removes a favorite by type and content_id.
  """
  def delete(conn, %{"type" => type, "content_id" => content_id}) do
    user = conn.assigns.current_user
    Favorites.remove(user.id, type, String.to_integer(content_id))
    send_resp(conn, 204, "")
  end

  @doc """
  POST /api/v1/favorites/toggle
  Toggles a favorite. Returns { "status": "added" | "removed" }
  """
  def toggle(conn, %{"type" => type, "content_id" => content_id}) do
    user = conn.assigns.current_user

    case Favorites.toggle(user.id, type, content_id) do
      {:ok, action} ->
        json(conn, %{status: Atom.to_string(action)})

      {:error, _} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "toggle_failed", message: "Failed to toggle favorite"}})
    end
  end

  # Auth plug — validates Bearer token
  defp authenticate(conn, _opts) do
    with token_str when is_binary(token_str) <- get_bearer_token(conn),
         {:ok, token} <- Base.url_decode64(token_str),
         {user, _inserted_at} <- Accounts.get_user_by_session_token(token) do
      assign(conn, :current_user, user)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: %{code: "unauthorized", message: "Invalid or missing token"}})
        |> halt()
    end
  end

  defp get_bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp parse_int(nil, default), do: default
  defp parse_int(val, _default) when is_integer(val), do: val

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(_, default), do: default
end
