defmodule StreamixWeb.Api.V1.HistoryController do
  @moduledoc """
  REST API for watch history management.
  Requires Bearer token authentication.
  Uses upsert (idempotent) for progress updates.
  """
  use StreamixWeb, :controller

  import StreamixWeb.Helpers.Params, only: [parse_positive_integer: 1]

  alias Streamix.Iptv

  plug StreamixWeb.Plugs.BearerAuth

  @doc """
  GET /api/v1/history
  Lists user's watch history. Query params: type, limit, offset
  """
  def index(conn, params) do
    user = conn.assigns.current_user

    opts = [
      content_type: params["type"],
      limit: parse_limit(params["limit"], 50),
      offset: parse_offset(params["offset"])
    ]

    items = Iptv.list_watch_history(user.id, opts)

    json(conn, %{
      items:
        Enum.map(items, fn h ->
          %{
            id: h.id,
            content_type: h[:content_type],
            content_id: h[:content_id],
            progress_seconds: h.progress_seconds,
            duration_seconds: h.duration_seconds,
            completed: h.completed,
            watched_at: h[:watched_at]
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

    case playable_history_target(user.id, type, content_id) do
      {:ok, content_id} ->
        progress = parse_int(params["progress_seconds"], 0)
        duration = parse_int(params["duration_seconds"], nil)
        completed = params["completed"] || false

        attrs = %{
          progress_seconds: progress,
          completed: completed
        }

        attrs = if duration, do: Map.put(attrs, :duration_seconds, duration), else: attrs

        case Iptv.add_watch_history(user.id, type, content_id, attrs) do
          {:ok, entry} ->
            conn
            |> put_status(:created)
            |> json(%{
              id: entry.id,
              content_type: entry[:content_type],
              content_id: entry[:content_id],
              progress_seconds: entry.progress_seconds,
              duration_seconds: entry.duration_seconds,
              completed: entry.completed
            })

          {:error, _changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: %{code: "save_failed", message: "Failed to save history"}})
        end

      {:error, :invalid_content_id} ->
        invalid_id(conn)

      {:error, :invalid_content_type} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_content_type", message: "Invalid content type"}})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "content_not_found", message: "Content not found"}})
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

    case parse_positive_integer(id) do
      {:ok, entry_id} ->
        Iptv.remove_from_watch_history(user.id, entry_id)
        send_resp(conn, 204, "")

      :error ->
        invalid_id(conn)
    end
  end

  # Auth plug

  defp parse_int(nil, default), do: default
  defp parse_int(val, _default) when is_integer(val), do: val

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

  defp parse_limit(value, default) do
    value
    |> parse_int(default)
    |> min(100)
    |> max(1)
  end

  defp parse_offset(value) do
    value
    |> parse_int(0)
    |> max(0)
  end

  defp invalid_id(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "invalid_id", message: "Invalid history id"}})
  end

  defp playable_history_target(user_id, type, raw_content_id) do
    with {:ok, content_id} <- parse_positive_integer(raw_content_id),
         true <- playable_history?(user_id, type, content_id) do
      {:ok, content_id}
    else
      :error -> {:error, :invalid_content_id}
      :invalid_content_type -> {:error, :invalid_content_type}
      false -> {:error, :not_found}
    end
  end

  defp playable_history?(user_id, "movie", content_id),
    do: not is_nil(Iptv.get_playable_movie(user_id, content_id))

  defp playable_history?(user_id, "episode", content_id),
    do: not is_nil(Iptv.get_playable_episode(user_id, content_id))

  defp playable_history?(user_id, "live_channel", content_id),
    do: not is_nil(Iptv.get_playable_channel(user_id, content_id))

  defp playable_history?(_user_id, _type, _content_id), do: :invalid_content_type
end
