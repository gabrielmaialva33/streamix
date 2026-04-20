defmodule StreamixWeb.OnMount.ProviderHealth do
  @moduledoc """
  LiveView `on_mount` hook that assigns the current upstream-provider
  health onto the socket as `:provider_health`.

  The assign mirrors `Streamix.Iptv.ProviderHealth.overall_status/0`
  plus a `:show_banner?` flag. `:show_banner?` is `true` when anything
  but `:healthy` is in play, so templates can bail out with a single
  `<%= if @provider_health.show_banner? do %>` check instead of
  repeating the status comparison.

  Lives as a separate hook (rather than inlining the computation into
  each mount) because the same result is needed by every public-facing
  LV — consolidating it here means a circuit-state change shows up
  consistently across `/browse`, `/favorites`, `/party`, etc.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Streamix.Iptv.ProviderHealthMonitor

  def on_mount(:default, _params, _session, socket) do
    # Read from the monitor's ETS cache — microsecond lookup, never
    # blocks the mount on an upstream probe. The monitor refreshes
    # itself every 30s in its own process, so this path is pure I/O
    # overhead from the LiveView's point of view.
    {:cont, assign(socket, :provider_health, ProviderHealthMonitor.get())}
  end
end
