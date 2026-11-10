defmodule StreamixWeb.PlayerEvents do
  @moduledoc """
  Player events that mean the same thing on every page that hosts the player.

  The standalone player and the Watch Party room both mount the same player
  hook, so track, quality, subtitle-offset, picture-in-picture, streaming-mode
  and lifecycle events have one handler here. `attach/1` installs it as a
  `handle_event` hook; events it does not know continue to the LiveView, which
  keeps the ones whose meaning depends on the page (progress, failover, errors).
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, push_event: 3, put_flash: 3]

  alias Streamix.Accounts
  alias StreamixWeb.Telemetry.PlayerLifecycle

  @streaming_modes %{
    "low_latency" => :low_latency,
    "balanced" => :balanced,
    "quality" => :quality,
    "adaptive" => :adaptive
  }

  @doc "Installs the shared player event handler on `socket`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket), do: attach_hook(socket, :player_events, :handle_event, &handle_event/3)

  @doc false
  def handle_event("player_lifecycle", params, socket) do
    PlayerLifecycle.observe(params)
    {:halt, socket}
  end

  def handle_event("set_audio_track", %{"track" => track}, socket),
    do: {:halt, push_event(socket, "set_audio_track", %{track: track})}

  def handle_event("set_subtitle_track", %{"track" => track}, socket),
    do: {:halt, push_event(socket, "set_subtitle_track", %{track: track})}

  def handle_event("set_quality", %{"level" => level}, socket),
    do: {:halt, push_event(socket, "set_quality", %{level: level})}

  def handle_event("toggle_pip", _params, socket),
    do: {:halt, push_event(socket, "toggle_pip", %{})}

  def handle_event("streaming_mode_changed", %{"mode" => mode}, socket),
    do: {:halt, assign(socket, :streaming_mode, Map.get(@streaming_modes, mode, :balanced))}

  def handle_event("reset_subtitle_offset", _params, socket),
    do: {:halt, update_subtitle_offset(socket, 0)}

  def handle_event("adjust_subtitle_offset", %{"delta" => delta}, socket) do
    case Integer.parse(to_string(delta)) do
      {delta, ""} ->
        offset = socket.assigns.current_scope.user.subtitle_offset_ms + delta
        {:halt, update_subtitle_offset(socket, offset)}

      _invalid ->
        {:halt, put_flash(socket, :error, "Ajuste de legenda inválido")}
    end
  end

  def handle_event(_event, _params, socket), do: {:cont, socket}

  defp update_subtitle_offset(socket, offset_ms) do
    scope = socket.assigns.current_scope

    case Accounts.update_user_settings(scope.user, %{subtitle_offset_ms: offset_ms}) do
      {:ok, user} ->
        socket
        |> assign(:current_scope, %{scope | user: user})
        |> push_event("subtitle_offset_changed", %{offset_ms: user.subtitle_offset_ms})

      {:error, _changeset} ->
        put_flash(socket, :error, "Não foi possível ajustar a legenda")
    end
  end
end
