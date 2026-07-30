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
    <nav
      id="admin-navigation"
      aria-label="Administração"
      class="-mx-4 mb-4 flex max-w-[calc(100%+2rem)] gap-1 overflow-x-auto border-b border-border px-4 scrollbar-hide sm:mx-0 sm:mb-6 sm:max-w-full sm:px-0"
    >
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
        label="Cobrança"
        icon="hero-banknotes"
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
    assigns = assign(assigns, :active, admin_tab_active?(assigns.current_path, assigns.path))

    ~H"""
    <.link
      navigate={@path}
      class={[
        "-mb-px flex min-h-11 shrink-0 items-center gap-2 border-b-2 px-3 py-2 text-sm font-medium transition-colors sm:px-4",
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
    <div class="rounded-lg border border-border bg-surface p-3 shadow-card sm:p-5">
      <div class="flex items-center gap-2.5 sm:gap-3">
        <div :if={@icon} class="rounded-lg bg-brand/10 p-2 sm:p-2.5">
          <.icon name={@icon} class="size-4 text-brand sm:size-5" />
        </div>
        <div class="min-w-0">
          <p class="truncate text-xs text-text-secondary sm:text-sm">{@label}</p>
          <p class="text-xl font-bold text-text-primary sm:text-2xl">{@value}</p>
        </div>
      </div>
    </div>
    """
  end

  attr :status, :string, required: true

  def status_badge(assigns) do
    assigns =
      assigns
      |> assign(:colors, status_colors(assigns.status))
      |> assign(:label, status_label(assigns.status))

    ~H"""
    <span class={[
      "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium border",
      @colors
    ]}>
      {@label}
    </span>
    """
  end

  def status_label("active"), do: "Ativa"
  def status_label("expired"), do: "Expirada"
  def status_label("canceled"), do: "Cancelada"
  def status_label("pending"), do: "Pendente"
  def status_label("paid"), do: "Pago"
  def status_label("failed"), do: "Falhou"
  def status_label("refunded"), do: "Reembolsado"
  def status_label("draft"), do: "Rascunho"
  def status_label("open"), do: "Em aberto"
  def status_label("void"), do: "Anulada"
  def status_label("uncollectible"), do: "Incobrável"
  def status_label("completed"), do: "Concluída"
  def status_label("admin"), do: "Administrador"
  def status_label("customer"), do: "Cliente"
  def status_label("moderator"), do: "Moderador"
  def status_label(status), do: status

  defp status_colors(status) when status in ~w(active paid completed),
    do: "bg-success/10 text-success border-success/20"

  defp status_colors(status) when status in ~w(expired failed uncollectible),
    do: "bg-error/10 text-error border-error/20"

  defp status_colors(status) when status in ~w(canceled refunded void),
    do: "bg-warning/10 text-warning border-warning/20"

  defp status_colors(status) when status in ~w(pending open draft moderator),
    do: "bg-info/10 text-info border-info/20"

  defp status_colors("admin"), do: "bg-accent/10 text-accent border-accent/20"
  defp status_colors(_status), do: "bg-gray-500/10 text-gray-400 border-gray-500/20"
end
