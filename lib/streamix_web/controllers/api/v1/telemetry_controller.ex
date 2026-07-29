defmodule StreamixWeb.Api.V1.TelemetryController do
  @moduledoc """
  REST API for client telemetry ingestion.

  Accepts batched playback metrics from mobile/TV apps.
  Samples are allowlisted, bounded and persisted for quality-of-experience
  analysis. Client retries are deduplicated by batch and sample index.
  """
  use StreamixWeb, :controller

  alias Streamix.Qoe

  plug StreamixWeb.Plugs.BearerAuth

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
      {:ok, result} = Qoe.ingest(user.id, batch_id, metrics)

      conn
      |> put_status(:accepted)
      |> json(result)
    end
  end

  def ingest(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "invalid_body", message: "Expected batch_id and metrics array"}})
  end

  # Auth plug

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
