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

  alias Streamix.Iptv.ProviderHealth

  def on_mount(:default, _params, _session, socket) do
    {:cont, assign(socket, :provider_health, compute())}
  end

  defp compute do
    %{status: status, counts: counts} = ProviderHealth.overall_status()

    %{
      status: status,
      counts: counts,
      show_banner?: status in [:degraded, :unhealthy]
    }
  rescue
    # Don't let a health-lookup hiccup take down a LiveView mount.
    # Worst case the banner hides itself — the app still works.
    _ ->
      %{status: :unknown, counts: %{}, show_banner?: false}
  end
end
