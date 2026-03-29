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
    <nav class="flex gap-1 border-b border-border mb-6">
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
        path={~p"/admin/users"}
        label="Usuários"
        icon="hero-users"
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
    assigns = assign(assigns, :active, String.starts_with?(assigns.current_path, assigns.path))

    ~H"""
    <.link
      navigate={@path}
      class={[
        "flex items-center gap-2 px-4 py-3 text-sm font-medium border-b-2 -mb-px transition-colors",
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

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :icon, :string, default: nil

  def stat_card(assigns) do
    ~H"""
    <div class="rounded-2xl border border-border bg-surface p-5">
      <div class="flex items-center gap-3">
        <div :if={@icon} class="rounded-xl bg-brand/10 p-2.5">
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
          "active" -> "bg-green-500/10 text-green-400 border-green-500/20"
          "expired" -> "bg-red-500/10 text-red-400 border-red-500/20"
          "canceled" -> "bg-yellow-500/10 text-yellow-400 border-yellow-500/20"
          "pending" -> "bg-blue-500/10 text-blue-400 border-blue-500/20"
          "admin" -> "bg-purple-500/10 text-purple-400 border-purple-500/20"
          "customer" -> "bg-gray-500/10 text-gray-400 border-gray-500/20"
          "moderator" -> "bg-blue-500/10 text-blue-400 border-blue-500/20"
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
