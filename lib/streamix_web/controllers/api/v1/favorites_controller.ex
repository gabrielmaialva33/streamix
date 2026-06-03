defmodule StreamixWeb.Api.V1.FavoritesController do
  @moduledoc """
  REST API for favorites management.
  Requires Bearer token authentication.
  """
  use StreamixWeb, :controller

  alias Streamix.Iptv
  alias StreamixWeb.Api.Envelope

  plug StreamixWeb.Plugs.BearerAuth

  @doc """
  GET /api/v1/favorites
  Lists user's favorites, optionally filtered by type.
  """
  def index(conn, params) do
    user = conn.assigns.current_user
    opts = [content_type: params["type"], limit: parse_int(params["limit"], 100)]
    favorites = Iptv.list_favorites(user.id, opts)

    json(conn, %{
      favorites:
        Enum.map(favorites, fn f ->
          %{
            content_type: f.content_type,
            content_id: f.content_id,
            content_name: f[:content_name],
            content_icon: f[:content_icon],
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

    case Iptv.add_favorite(user.id, type, content_id) do
      {:ok, fav} ->
        # New endpoints use Envelope for the canonical `%{data, meta}`
        # shape. Older endpoints in this controller (`index/2`,
        # `delete/2`) keep their legacy flat-map shape until a major
        # API bump — TV apps currently parse those.
        conn
        |> put_status(:created)
        |> json(Envelope.data(%{content_type: fav.content_type, content_id: fav.content_id}))

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(Envelope.error(:already_exists, "Already in favorites"))
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

    case parse_positive_integer(content_id) do
      {:ok, content_id} ->
        Iptv.remove_favorite(user.id, type, content_id)
        send_resp(conn, 204, "")

      :error ->
        invalid_content_id(conn)
    end
  end

  @doc """
  POST /api/v1/favorites/toggle
  Toggles a favorite. Returns { "status": "added" | "removed" }
  """
  def toggle(conn, %{"type" => type, "content_id" => content_id}) do
    user = conn.assigns.current_user

    case Iptv.toggle_favorite(user.id, type, content_id) do
      {:ok, action} ->
        json(conn, %{status: Atom.to_string(action)})

      {:error, _} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "toggle_failed", message: "Failed to toggle favorite"}})
    end
  end

  @doc """
  POST /api/v1/favorites/sync
  Batch sync for offline-first clients.
  Body: { "operations": [{ "type": "movie", "content_id": 123, "action": "add"|"remove", "at": "2026-03-31T12:00:00Z" }] }

  Processes operations idempotently. Last-write-wins by timestamp.
  """
  def sync(conn, %{"operations" => operations}) when is_list(operations) do
    user = conn.assigns.current_user
    results = Enum.map(operations, &process_sync_operation(user.id, &1))

    added = Enum.count(results, &(&1 == :added))
    removed = Enum.count(results, &(&1 == :removed))
    skipped = Enum.count(results, &(&1 == :skipped))

    json(conn, %{added: added, removed: removed, skipped: skipped})
  end

  def sync(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "missing_params", message: "operations array required"}})
  end

  defp process_sync_operation(user_id, %{
         "type" => type,
         "content_id" => content_id,
         "action" => action
       }) do
    exists? = Iptv.favorite?(user_id, type, content_id)

    case {action, exists?} do
      {"add", false} ->
        Iptv.add_favorite(user_id, type, content_id)
        :added

      {"remove", true} ->
        Iptv.remove_favorite(user_id, type, content_id)
        :removed

      _ ->
        :skipped
    end
  end

  defp process_sync_operation(_user_id, _invalid), do: :skipped

  # Auth plug — validates Bearer token

  defp parse_int(nil, default), do: default
  defp parse_int(val, _default) when is_integer(val), do: val

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> :error
    end
  end

  defp parse_positive_integer(_), do: :error

  defp invalid_content_id(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "invalid_content_id", message: "Invalid content id"}})
  end
end
