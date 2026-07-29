defmodule StreamixWeb.OnMount.ClientTelemetry do
  @moduledoc """
  Auth-aware, bounded ingestion hook for browser QoE events.

  The per-LiveView budget prevents a buggy or hostile hook from turning a
  socket into an unbounded write stream.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Streamix.Qoe

  require Logger

  @event_budget 12

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:client_telemetry_count, 0)
      |> attach_hook(:client_telemetry, :handle_event, &handle_event/3)

    {:cont, socket}
  end

  defp handle_event("client_telemetry", params, socket) when is_map(params) do
    count = socket.assigns.client_telemetry_count

    if count < @event_budget do
      user_id =
        case socket.assigns[:current_scope] do
          %{user: %{id: id}} -> id
          _ -> nil
        end

      persist_event(user_id, params)
      {:halt, assign(socket, :client_telemetry_count, count + 1)}
    else
      {:halt, socket}
    end
  end

  defp handle_event("client_telemetry", _params, socket), do: {:halt, socket}
  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp persist_event(user_id, params) do
    case Qoe.record_client_event(user_id, params) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("[QoE] LiveView sample rejected: #{inspect(reason)}")
    end
  rescue
    error ->
      Logger.warning("[QoE] LiveView sample persistence failed: #{Exception.message(error)}")
  end
end
