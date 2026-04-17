defmodule StreamixWeb.LiveAcceptance do
  @moduledoc """
  LiveView `on_mount` callback that allows Playwright E2E tests to share the
  test process's Ecto sandbox with LiveView processes.

  Only hooked in when `:sql_sandbox` is enabled (test env). No-op in prod.
  See `Phoenix.Ecto.SQL.Sandbox` for the protocol.
  """

  import Phoenix.Component, only: [assign_new: 3]
  import Phoenix.LiveView, only: [connected?: 1, get_connect_info: 2]

  def on_mount(:default, _params, _session, socket) do
    socket =
      assign_new(socket, :phoenix_ecto_sandbox, fn ->
        if connected?(socket), do: get_connect_info(socket, :user_agent)
      end)

    Phoenix.Ecto.SQL.Sandbox.allow(
      socket.assigns.phoenix_ecto_sandbox,
      Ecto.Adapters.SQL.Sandbox
    )

    {:cont, socket}
  end
end
