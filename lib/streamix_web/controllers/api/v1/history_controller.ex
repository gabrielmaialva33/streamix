defmodule StreamixWeb.Api.V1.HistoryController do
  @moduledoc """
  REST API for watch history management.
  Requires Bearer token authentication.
  Uses upsert (idempotent) for progress updates.
  """
  use StreamixWeb, :controller

  alias Streamix.Accounts
  alias Streamix.Iptv.History

  plug :authenticate

  @doc """
  GET /api/v1/history
  Lists user's watch history. Query params: type, limit, offset
  """
  def index(conn, params) do
    user = conn.assigns.current_user

    opts = [
      content_type: params["type"],
      limit: parse_int(params["limit"], 50),
      offset: parse_int(params["offset"], 0)
    ]

    items = History.list(user.id, opts)

    json(conn, %{
      items:
        Enum.map(items, fn h ->
          %{
            id: h.id,
            content_type: h.content_type,
            content_id: h.content_id,
            progress_seconds: h.progress_seconds,
            duration_seconds: h.duration_seconds,
            completed: h.completed,
            watched_at: h.watched_at
          }
        end)
    })
  end

  @doc """
  POST /api/v1/history
  Upsert watch progress. Idempotent by (user_id, content_type, content_id).
  Body: { "type": "movie", "content_id": 123, "progress_seconds": 3600, "duration_seconds": 7200, "completed": false }
  """
  def upsert(conn, %{"type" => type, "content_id" => content_id} = params) do
    user = conn.assigns.current_user

    progress = parse_int(params["progress_seconds"], 0)
    duration = parse_int(params["duration_seconds"], nil)
    completed = params["completed"] || false

    attrs = %{
      progress_seconds: progress,
      completed: completed
    }

    attrs = if duration, do: Map.put(attrs, :duration_seconds, duration), else: attrs

    case History.add(user.id, type, content_id, attrs) do
      {:ok, entry} ->
        conn
        |> put_status(:created)
        |> json(%{
          id: entry.id,
          content_type: entry.content_type,
          content_id: entry.content_id,
          progress_seconds: entry.progress_seconds,
          duration_seconds: entry.duration_seconds,
          completed: entry.completed
        })

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "save_failed", message: "Failed to save history"}})
    end
  end

  def upsert(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "missing_params", message: "type and content_id required"}})
  end

  @doc """
  DELETE /api/v1/history/:id
  Removes a single history entry.
  """
  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user
    History.remove(user.id, String.to_integer(id))
    send_resp(conn, 204, "")
  end

  # Auth plug
  defp authenticate(conn, _opts) do
    case get_bearer_token(conn) do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: %{code: "unauthorized", message: "Bearer token required"}})
        |> halt()

      token_str ->
        case Base.url_decode64(token_str) do
          {:ok, token} ->
            case Accounts.get_user_by_session_token(token) do
              {user, _inserted_at} ->
                assign(conn, :current_user, user)

              nil ->
                conn
                |> put_status(:unauthorized)
                |> json(%{error: %{code: "unauthorized", message: "Invalid or expired token"}})
                |> halt()
            end

          :error ->
            conn
            |> put_status(:unauthorized)
            |> json(%{error: %{code: "unauthorized", message: "Malformed token"}})
            |> halt()
        end
    end
  end

  defp get_bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp parse_int(nil, default), do: default
  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end
  defp parse_int(_, default), do: default
end
