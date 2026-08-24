defmodule StreamixWeb.Api.V1.FavoritesController do
  @moduledoc """
  REST API for favorites management.
  Requires Bearer token authentication.
  """
  use StreamixWeb, :controller

  import StreamixWeb.Helpers.Params,
    only: [bounded_integer: 4, parse_positive_integer: 1]

  alias Streamix.Library
  alias StreamixWeb.Api.Envelope
  alias StreamixWeb.Api.V1.Response

  plug StreamixWeb.Plugs.BearerAuth

  @content_types ~w(movie series episode live_channel)
  @max_sync_operations 500

  @doc """
  GET /api/v1/favorites
  Lists user's favorites, optionally filtered by type.
  """
  def index(conn, params) do
    user = conn.assigns.current_user

    opts = [
      content_type: params["type"],
      limit: bounded_integer(params["limit"], 100, 1, 100),
      show_adult: user.show_adult_content
    ]

    favorites = Library.list_favorites(user.id, opts)

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

    case playable_favorite_target(user.id, type, content_id) do
      {:ok, content_id} ->
        case Library.add_favorite(user.id, type, content_id) do
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

      {:error, :invalid_content_id} ->
        invalid_content_id(conn)

      {:error, :invalid_content_type} ->
        invalid_content_type(conn)

      {:error, :not_found} ->
        content_not_found(conn)
    end
  end

  def create(conn, _params) do
    Response.error(conn, :bad_request, "missing_params", "type and content_id required")
  end

  @doc """
  DELETE /api/v1/favorites/:type/:content_id
  Removes a favorite by type and content_id.
  """
  def delete(conn, %{"type" => type, "content_id" => content_id}) do
    user = conn.assigns.current_user

    with true <- type in @content_types,
         {:ok, content_id} <- parse_positive_integer(content_id) do
      Library.remove_favorite(user.id, type, content_id)
      send_resp(conn, 204, "")
    else
      false ->
        invalid_content_type(conn)

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

    with {:ok, content_id} <- parse_positive_integer(content_id),
         true <- favorite_or_playable?(user.id, type, content_id) do
      case Library.toggle_favorite(user.id, type, content_id) do
        {:ok, action} ->
          json(conn, %{status: Atom.to_string(action)})

        {:error, _} ->
          Response.error(
            conn,
            :unprocessable_entity,
            "toggle_failed",
            "Failed to toggle favorite"
          )
      end
    else
      :error ->
        invalid_content_id(conn)

      false ->
        content_not_found(conn)

      :invalid_content_type ->
        invalid_content_type(conn)
    end
  end

  @doc """
  POST /api/v1/favorites/sync
  Batch sync for offline-first clients.
  Body: { "operations": [{ "type": "movie", "content_id": 123, "action": "add"|"remove", "at": "2026-03-31T12:00:00Z" }] }

  Processes operations idempotently. Last-write-wins by timestamp.
  """
  def sync(conn, %{"operations" => operations}) when is_list(operations) do
    if length(operations) <= @max_sync_operations do
      user = conn.assigns.current_user
      {operations, pre_skipped} = latest_sync_operations(operations)
      results = Enum.map(operations, &process_sync_operation(user.id, &1))

      added = Enum.count(results, &(&1 == :added))
      removed = Enum.count(results, &(&1 == :removed))
      skipped = pre_skipped + Enum.count(results, &(&1 == :skipped))

      json(conn, %{added: added, removed: removed, skipped: skipped})
    else
      Response.error(
        conn,
        413,
        "too_many_operations",
        "A favorites sync batch accepts at most #{@max_sync_operations} operations"
      )
    end
  end

  def sync(conn, _params) do
    Response.error(conn, :bad_request, "missing_params", "operations array required")
  end

  defp process_sync_operation(user_id, %{type: type, content_id: content_id, action: action}) do
    process_parsed_sync_operation(user_id, type, content_id, action)
  end

  defp process_parsed_sync_operation(user_id, type, content_id, action) do
    exists? = Library.favorite?(user_id, type, content_id)

    case {action, exists?} do
      {"add", false} -> sync_add_favorite(user_id, type, content_id)
      {"remove", true} -> sync_remove_favorite(user_id, type, content_id)
      _ -> :skipped
    end
  end

  defp sync_add_favorite(user_id, type, content_id) do
    case playable_favorite_target(user_id, type, content_id) do
      {:ok, content_id} ->
        Library.add_favorite(user_id, type, content_id)
        :added

      {:error, _} ->
        :skipped
    end
  end

  defp sync_remove_favorite(user_id, type, content_id) do
    Library.remove_favorite(user_id, type, content_id)
    :removed
  end

  defp invalid_content_id(conn) do
    Response.error(conn, :bad_request, "invalid_content_id", "Invalid content id")
  end

  defp invalid_content_type(conn) do
    Response.error(
      conn,
      :unprocessable_entity,
      "invalid_content_type",
      "Invalid content type"
    )
  end

  defp content_not_found(conn) do
    Response.error(conn, :not_found, "content_not_found", "Content not found")
  end

  defp playable_favorite_target(user_id, type, raw_content_id) do
    with {:ok, content_id} <- parse_positive_integer(raw_content_id),
         true <- playable_favorite?(user_id, type, content_id) do
      {:ok, content_id}
    else
      :error -> {:error, :invalid_content_id}
      :invalid_content_type -> {:error, :invalid_content_type}
      false -> {:error, :not_found}
    end
  end

  defp playable_favorite?(user_id, "movie", content_id),
    do: not is_nil(Streamix.Playback.get_playable_movie(user_id, content_id))

  defp playable_favorite?(user_id, "series", content_id),
    do: not is_nil(Streamix.Playback.get_playable_series(user_id, content_id))

  defp playable_favorite?(user_id, "episode", content_id),
    do: not is_nil(Streamix.Playback.get_playable_episode(user_id, content_id))

  defp playable_favorite?(user_id, "live_channel", content_id),
    do: not is_nil(Streamix.Playback.get_playable_channel(user_id, content_id))

  defp playable_favorite?(_user_id, _type, _content_id), do: :invalid_content_type

  defp favorite_or_playable?(user_id, type, content_id) do
    if Library.favorite?(user_id, type, content_id) do
      true
    else
      playable_favorite?(user_id, type, content_id)
    end
  end

  defp latest_sync_operations(operations) do
    {latest, skipped} =
      operations
      |> Enum.with_index()
      |> Enum.reduce({%{}, 0}, &reduce_sync_operation/2)

    operations =
      latest
      |> Map.values()
      |> Enum.sort_by(& &1.index)

    {operations, skipped}
  end

  defp reduce_sync_operation({operation, index}, {latest, skipped}) do
    case normalize_sync_operation(operation, index) do
      {:ok, key, candidate} ->
        duplicate? = Map.has_key?(latest, key)
        latest = Map.update(latest, key, candidate, &latest_candidate(candidate, &1))
        {latest, skipped + if(duplicate?, do: 1, else: 0)}

      :error ->
        {latest, skipped + 1}
    end
  end

  defp latest_candidate(candidate, current) do
    if newer_operation?(candidate, current), do: candidate, else: current
  end

  defp normalize_sync_operation(
         %{"type" => type, "content_id" => raw_content_id, "action" => action} = operation,
         index
       )
       when type in @content_types and action in ["add", "remove"] do
    case parse_positive_integer(raw_content_id) do
      {:ok, content_id} ->
        candidate = %{
          type: type,
          content_id: content_id,
          action: action,
          timestamp: parse_operation_timestamp(operation["at"]),
          index: index
        }

        {:ok, {type, content_id}, candidate}

      :error ->
        :error
    end
  end

  defp normalize_sync_operation(_operation, _index), do: :error

  defp parse_operation_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> DateTime.to_unix(timestamp, :microsecond)
      {:error, _reason} -> nil
    end
  end

  defp parse_operation_timestamp(_value), do: nil

  defp newer_operation?(%{timestamp: left}, %{timestamp: right})
       when is_integer(left) and is_integer(right),
       do: left >= right

  defp newer_operation?(%{timestamp: timestamp}, %{timestamp: nil}) when is_integer(timestamp),
    do: true

  defp newer_operation?(%{timestamp: nil}, %{timestamp: timestamp}) when is_integer(timestamp),
    do: false

  defp newer_operation?(left, right), do: left.index >= right.index
end
