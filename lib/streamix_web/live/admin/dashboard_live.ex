defmodule StreamixWeb.Admin.DashboardLive do
  use StreamixWeb, :live_view

  import StreamixWeb.AdminComponents

  alias Streamix.{Accounts, Billing}

  def mount(_params, _session, socket) do
    stats = Billing.admin_stats()
    recent_users = Accounts.list_users(page: 1, per_page: 10)
    recent_subs = Billing.list_subscriptions([]) |> Enum.take(10)

    socket =
      socket
      |> assign(page_title: "Admin — Dashboard", current_path: "/admin")
      |> assign(stats: stats)
      |> assign(recent_users: recent_users)
      |> assign(recent_subs: recent_subs)

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div id="admin-dashboard" class="space-y-6">
      <.admin_tabs current_path={@current_path} />

      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <.stat_card label="Total Usuários" value={"#{@stats.total_users}"} icon="hero-users" />
        <.stat_card
          label="Subscriptions Ativas"
          value={"#{@stats.active_subscriptions}"}
          icon="hero-check-badge"
        />
        <.stat_card label="Planos Ativos" value={"#{@stats.active_plans}"} icon="hero-credit-card" />
        <.stat_card
          label="Receita Mensal"
          value={format_revenue(@stats.monthly_revenue_cents)}
          icon="hero-currency-dollar"
        />
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <section class="rounded-2xl border border-border bg-surface p-5">
          <h2 class="text-lg font-semibold text-text-primary mb-4">Últimos Usuários</h2>
          <table class="w-full text-sm">
            <thead>
              <tr class="text-left text-text-muted border-b border-border">
                <th class="pb-2">Email</th>
                <th class="pb-2">Role</th>
                <th class="pb-2">Registrado</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={user <- @recent_users} class="border-b border-border/50">
                <td class="py-2 text-text-primary">{user.email}</td>
                <td class="py-2"><.status_badge status={user.role} /></td>
                <td class="py-2 text-text-secondary">
                  {Calendar.strftime(user.inserted_at, "%d/%m/%Y")}
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <section class="rounded-2xl border border-border bg-surface p-5">
          <h2 class="text-lg font-semibold text-text-primary mb-4">Últimas Subscriptions</h2>
          <table class="w-full text-sm">
            <thead>
              <tr class="text-left text-text-muted border-b border-border">
                <th class="pb-2">Usuário</th>
                <th class="pb-2">Plano</th>
                <th class="pb-2">Status</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={sub <- @recent_subs} class="border-b border-border/50">
                <td class="py-2 text-text-primary">{sub.user.email}</td>
                <td class="py-2 text-text-secondary">{sub.plan.name}</td>
                <td class="py-2"><.status_badge status={sub.status} /></td>
              </tr>
              <tr :if={@recent_subs == []}>
                <td colspan="3" class="py-4 text-center text-text-muted">Nenhuma subscription</td>
              </tr>
            </tbody>
          </table>
        </section>
      </div>
    </div>
    """
  end

  defp format_revenue(cents) when is_integer(cents) do
    value = cents / 100
    amount = :erlang.float_to_binary(value, decimals: 2) |> String.replace(".", ",")
    "R$ #{amount}"
  end

  defp format_revenue(_), do: "R$ 0,00"
end
