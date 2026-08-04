defmodule StreamixWeb.Api.V1.HistoryController do
  @moduledoc """
  REST API for watch history management.
  Requires Bearer token authentication.
  Uses upsert (idempotent) for progress updates.
  """
  use StreamixWeb, :controller

  import StreamixWeb.Helpers.Params,
    only: [
      bounded_integer: 4,
      parse_boolean: 2,
      parse_non_negative_integer: 1,
      parse_positive_integer: 1
    ]

  alias Streamix.Iptv
  alias StreamixWeb.Api.V1.Response

  plug StreamixWeb.Plugs.BearerAuth

  @doc """
  GET /api/v1/history
  Lists user's watch history. Query params: type, limit, offset
  """
  def index(conn, params) do
    user = conn.assigns.current_user

    opts = [
      content_type: params["type"],
      limit: bounded_integer(params["limit"], 50, 1, 100),
      offset: bounded_integer(params["offset"], 0, 0, 100_000),
      show_adult: user.show_adult_content
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
        case progress_attrs(params) do
          {:ok, attrs} ->
            save_history(conn, user.id, type, content_id, attrs)

          :error ->
            Response.error(
              conn,
              :bad_request,
              "invalid_progress",
              "Progress, duration, or completed value is invalid"
            )
        end

      {:error, :invalid_content_id} ->
        invalid_id(conn)

      {:error, :invalid_content_type} ->
        Response.error(
          conn,
          :unprocessable_entity,
          "invalid_content_type",
          "Invalid content type"
        )

      {:error, :not_found} ->
        Response.error(conn, :not_found, "content_not_found", "Content not found")
    end
  end

  def upsert(conn, _params) do
    Response.error(conn, :bad_request, "missing_params", "type and content_id required")
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

  defp invalid_id(conn) do
    Response.error(conn, :bad_request, "invalid_id", "Invalid history id")
  end

  defp progress_attrs(params) do
    with {:ok, progress} <-
           parse_non_negative_integer(Map.get(params, "progress_seconds", 0)),
         {:ok, duration} <- parse_optional_duration(params["duration_seconds"]),
         {:ok, completed} <- parse_boolean(params["completed"], false) do
      attrs = %{progress_seconds: progress, completed: completed}
      {:ok, if(is_nil(duration), do: attrs, else: Map.put(attrs, :duration_seconds, duration))}
    else
      :error -> :error
    end
  end

  defp parse_optional_duration(nil), do: {:ok, nil}
  defp parse_optional_duration(value), do: parse_non_negative_integer(value)

  defp save_history(conn, user_id, type, content_id, attrs) do
    case Iptv.add_watch_history(user_id, type, content_id, attrs) do
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
        Response.error(
          conn,
          :unprocessable_entity,
          "save_failed",
          "Failed to save history"
        )
    end
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
