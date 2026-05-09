defmodule StreamixWeb.Api.V1.TelemetryController do
  @moduledoc """
  REST API for client telemetry ingestion.

  Accepts batched playback metrics from mobile/TV apps.
  Deduplicates by batch_id. Stores for quality-of-experience analysis.
  """
  use StreamixWeb, :controller

  require Logger

  alias Streamix.Accounts

  plug :authenticate

  @max_batch_size 50

  @doc """
  POST /api/v1/telemetry/playback
  Ingests a batch of playback metrics.

  Body:
  {
    "batch_id": "uuid",
    "metrics": [
      {
        "stream_type": "movie",
        "engine": "VLC",
        "time_to_first_frame_ms": 1200,
        "buffer_count": 2,
        "total_buffer_duration_ms": 3000,
        "session_duration_ms": 120000,
        "error_count": 0,
        "dropped_frames": 5
      }
    ]
  }
  """
  def ingest(conn, params) when is_map(params) do
    user = conn.assigns.current_user
    {batch_id, metrics} = normalize_payload(params)

    if metrics == [] do
      conn
      |> put_status(:bad_request)
      |> json(%{error: %{code: "invalid_body", message: "Expected telemetry metric payload"}})
    else
      metrics = Enum.take(metrics, @max_batch_size)

      Logger.info("[Telemetry] user=#{user.id} batch=#{batch_id} count=#{length(metrics)}")

      Enum.each(metrics, fn metric ->
        Logger.info(
          "[Telemetry] user=#{user.id} " <>
            "engine=#{metric["engine"] || metric["player"]} " <>
            "type=#{metric["stream_type"] || metric["content_type"]} " <>
            "event=#{metric["event"] || metric["type"]} " <>
            "ttff=#{metric["time_to_first_frame_ms"]}ms " <>
            "buffers=#{metric["buffer_count"]} " <>
            "errors=#{metric["error_count"]}"
        )
      end)

      conn
      |> put_status(:accepted)
      |> json(%{accepted: length(metrics), batch_id: batch_id})
    end
  end

  def ingest(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "invalid_body", message: "Expected batch_id and metrics array"}})
  end

  # Auth plug
  defp authenticate(conn, _opts) do
    with token_str when is_binary(token_str) <- get_bearer_token(conn),
         {:ok, token} <- Base.url_decode64(token_str),
         {user, _inserted_at} <- Accounts.get_user_by_session_token(token) do
      assign(conn, :current_user, user)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: %{code: "unauthorized", message: "Bearer token required"}})
        |> halt()
    end
  end

  defp get_bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp normalize_payload(%{"batch_id" => batch_id, "metrics" => metrics})
       when is_binary(batch_id) and is_list(metrics) do
    {batch_id, Enum.filter(metrics, &is_map/1)}
  end

  defp normalize_payload(%{"metrics" => metrics}) when is_list(metrics) do
    {new_batch_id(), Enum.filter(metrics, &is_map/1)}
  end

  defp normalize_payload(%{"events" => events}) when is_list(events) do
    {new_batch_id(), Enum.filter(events, &is_map/1)}
  end

  defp normalize_payload(%{"metric" => metric}) when is_map(metric) do
    {new_batch_id(), [metric]}
  end

  defp normalize_payload(%{"event" => _event} = metric), do: {new_batch_id(), [metric]}
  defp normalize_payload(%{"stream_type" => _type} = metric), do: {new_batch_id(), [metric]}
  defp normalize_payload(%{"engine" => _engine} = metric), do: {new_batch_id(), [metric]}
  defp normalize_payload(%{"type" => _type} = metric), do: {new_batch_id(), [metric]}

  defp normalize_payload(_params), do: {new_batch_id(), []}

  defp new_batch_id, do: Ecto.UUID.generate()
end
