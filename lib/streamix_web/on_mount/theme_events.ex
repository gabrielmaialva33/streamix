defmodule StreamixWeb.OnMount.ThemeEvents do
  @moduledoc """
  Consumes the client-only theme initialization event for every LiveView.
  """

  import Phoenix.LiveView, only: [attach_hook: 4]

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :theme_events, :handle_event, &handle_event/3)}
  end

  defp handle_event("theme_init", _params, socket), do: {:halt, socket}
  defp handle_event(_event, _params, socket), do: {:cont, socket}
end
