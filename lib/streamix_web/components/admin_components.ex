defmodule StreamixWeb.AdminComponents do
  @moduledoc """
  Shared UI components for the admin panel.
  """
  use Phoenix.Component
  use StreamixWeb, :verified_routes

  import StreamixWeb.CoreComponents

  attr :current_path, :string, required: true

  def admin_tabs(assigns) do
    ~H"""
    <nav class="flex max-w-full gap-1 overflow-x-auto border-b border-border mb-6">
      <.admin_tab
        path={~p"/admin"}
        label="Dashboard"
        icon="hero-chart-bar"
        current_path={@current_path}
      />
      <.admin_tab
        path={~p"/admin/plans"}
        label="Planos"
        icon="hero-credit-card"
        current_path={@current_path}
      />
      <.admin_tab
        path={~p"/admin/billing"}
        label="Billing"
        icon="hero-banknotes"
        current_path={@current_path}
      />
      <.admin_tab
        path={~p"/admin/users"}
        label="Usuários"
        icon="hero-users"
        current_path={@current_path}
      />
      <.admin_tab
        path={~p"/debug/pwa"}
        label="PWA Debug"
        icon="hero-device-phone-mobile"
        current_path={@current_path}
      />
    </nav>
    """
  end

  attr :path, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :current_path, :string, required: true

  defp admin_tab(assigns) do
    assigns = assign(assigns, :active, admin_tab_active?(assigns.current_path, assigns.path))

    ~H"""
    <.link
      navigate={@path}
      class={[
        "flex shrink-0 items-center gap-2 px-4 py-3 text-sm font-medium border-b-2 -mb-px transition-colors",
        @active && "border-brand text-brand",
        !@active &&
          "border-transparent text-text-secondary hover:text-text-primary hover:border-border"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
    </.link>
    """
  end

  defp admin_tab_active?(current_path, "/admin"), do: current_path == "/admin"
  defp admin_tab_active?(current_path, path), do: String.starts_with?(current_path, path)

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :icon, :string, default: nil

  def stat_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-border bg-surface p-5 shadow-card">
      <div class="flex items-center gap-3">
        <div :if={@icon} class="rounded-lg bg-brand/10 p-2.5">
          <.icon name={@icon} class="size-5 text-brand" />
        </div>
        <div>
          <p class="text-sm text-text-secondary">{@label}</p>
          <p class="text-2xl font-bold text-text-primary">{@value}</p>
        </div>
      </div>
    </div>
    """
  end

  attr :status, :string, required: true

  def status_badge(assigns) do
    assigns =
      assign(
        assigns,
        :colors,
        case assigns.status do
          "active" -> "bg-success/10 text-success border-success/20"
          "expired" -> "bg-error/10 text-error border-error/20"
          "canceled" -> "bg-warning/10 text-warning border-warning/20"
          "pending" -> "bg-info/10 text-info border-info/20"
          "admin" -> "bg-accent/10 text-accent border-accent/20"
          "customer" -> "bg-gray-500/10 text-gray-400 border-gray-500/20"
          "moderator" -> "bg-info/10 text-info border-info/20"
          _ -> "bg-gray-500/10 text-gray-400 border-gray-500/20"
        end
      )

    ~H"""
    <span class={[
      "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium border",
      @colors
    ]}>
      {@status}
    </span>
    """
  end
end
